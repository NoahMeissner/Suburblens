# Suburblens

A medallion pipeline over NSW open data, with **Sydney bus stops as the reference
point**: every source is reduced to a per-stop measure so one table answers
"what is happening around this stop" — plus a website that turns an address into
a one-page report and a map.

## Team

| Name |
|---|
| Noah Meißner |
| Kang Donghyun |
| Wujie Liang |
| Ryo Arimura |
| Taekyun Kim |

## Installation

1. Download the Raw Folder from Google Drive and put all the files in `data/raw/`
2. Install Docker, then run `./start.sh`
3. Run `python -m pipeline.run`

```
./start.sh stop     stop docker (data is kept)
./start.sh reset    kill the databases
./start.sh purge    kill everything that was installed before
```

## Layers

| Layer | Code | Schema | Rule |
|---|---|---|---|
| Bronze | `pipeline/bronze/` | `bronze` | Unaltered copy of the source. Rows in the file == rows in the table |
| Silver | `pipeline/silver/` | `silver` | Typed, standardised, quality-flagged, mapped onto bus stops. Problems get a `flag_*` column; nothing is deleted |
| Gold | `pipeline/gold/` | `gold` + Neo4j | Serving layer: one graph, comparison marts, the tables the site reads. Reads Silver only |
| Website | `web/` | — | Address → report + map, via one `get_report()` function |

```bash
python -m pipeline.run                 # every layer, then the quality checks
python -m pipeline.run --skip-graph     # everything except the Neo4j load
python -m pipeline.quality              # all checks
python -m test.web_smoke                # site routes vs. SQL
```

## The website

```bash
./start.sh && python -m pipeline.run    # once
python -m web.app                       # http://127.0.0.1:5000
```

| Screen | What it does |
|---|---|
| `/` | Type an address. Autocomplete over 147,561 points, trigram-ranked |
| `/report?address=…&at=peak\|offpeak` | A4 report: schools, street activity, commute, market |
| `/map?address=…&at=peak\|offpeak` | The same findings as toggleable Leaflet layers |

`?at=` is the service band (peak/off-peak — there's no raw GTFS feed, so no finer
detail exists); the URL carries it so a link reproduces exactly what you saw.
Built from the design handoff in `design/` (`DESIGN.md` is the spec).

A few deliberate calls worth knowing about:

- **One-page PDF**: "Download PDF" is the browser's own print. The report prints
  as one A4 page by scoping the responsive grid to `screen`, forcing background
  colours with `print-color-adjust`, and giving `@page` real margins.
- **No noise data** → section 02 reports scheduled bus traffic instead, on real
  geometry, and says so on the page.
- **Reach** starts from every stop within walking distance (not just the
  closest one), via a Postgres recursive CTE — ~100x faster than the Neo4j GDS
  equivalent for this multi-source case.
- **Rankings** publish both median price and price/m² because they can
  disagree (e.g. Ultimo is cheap by median, expensive per m² — it's mostly
  small apartments); the report flags that divergence automatically.
- **Geocoding** has no G-NAF: addresses fall back to street-centre points when
  the exact house number isn't known, and low-confidence matches return nothing
  rather than a wrong guess. Precision is always shown alongside the number.

`python -m pipeline.run` exits non-zero on any failed quality check.

## What silver produces

`silver.bus_stop_profile` is the deliverable: one row per bus stop, every source joined.

| Measure | Table | How it reaches a stop |
|---|---|---|
| Development applications | `da_hex_300m`, `bus_stop_da` | 300 m hexagon + k-ring-1 average |
| Property sales | `property_sales_hex_300m`, `bus_stop_property_sales` | same hexagon + k-ring-1 average |
| Schools | `bus_stop_school`, `bus_stop_school_summary` | every stop within 200 m |
| Transit travel time | `bus_edge`, `bus_edge_travel_time` | per stop-to-stop edge, per time band |
| Traffic volume | `traffic_segment_daypart`, `bus_stop_traffic` | stops within 500 m |

## The graph

`gold.graph_node` / `gold.graph_edge` in Postgres are the contract; `pipeline/gold/graph.py`
projects them into Neo4j for Cypher and GDS — so the graph is checkable in SQL
and still builds when Neo4j is down.

| Node | Count | Relationship | Count |
|---|---:|---|---:|
| `Stop` | 23,427 | `CONNECTS` (routing) | 28,340 |
| `School` | 1,077 | `ROUTE_SEGMENT` | 47,047 |
| `LGA` | 33 | `NEAR_SCHOOL` | 2,209 |
| `Route` | 602 | `SERVES` | 46,265 |

`travel_time_s` (the routing weight) is never NULL or zero — both break GDS
silently — and falls back `best_peak → avg_peak → best_offpeak → avg_offpeak →
distance estimate`, with `weight_source` recording which was used.

Neo4j Browser: http://localhost:7474 (`grep NEO4J_PASSWORD .env`).

## Comparison marts

| Table | Grain | Answers |
|---|---|---|
| `gold.lga_comparison` | 33 LGAs | highest rent, most development, dearest sales, most stops (`rank_*` columns) |
| `gold.suburb_comparison` | 776 suburbs | median price, price/m², 5-year growth, each with a percentile and a % gap to the Sydney median |
| `gold.traffic_ranking` | 6 segments | most traffic by rush / non-rush / night |

`silver.lga` is the conformed LGA dimension these rest on — one `silver.lga_key()`
function resolves four different spellings per council to the same key.

**Spatial conventions**: `geom` is EPSG:4326, `geom_m` is EPSG:7856 (GDA2020 /
MGA zone 56) and all distances use it. `silver.hex_300m` is a real 300 m hex
grid; `silver.hex_300m_neighbour` (the k-ring) is the headline figure for DA
and sales, since most individual cells are empty.

**Reading the numbers safely**: `has_*_data` flags on `bus_stop_profile`
distinguish "nothing there" from "not ingested" — don't `coalesce` past them.
Aggregates use `is_usable` rows only; failed rows keep their `flag_*` and stay
in the table. Every quality check's outcome is itself stored, in `silver.dq_run`.

## Known data gaps

| Gap | Size | What it means |
|---|---:|---|
| No raw GTFS feed | — | Only pre-computed peak/offpeak bands exist, not finer windows |
| Property sales have no coordinates | all rows | Geocoded to street centre from DA points (p50 error 86 m) |
| No traffic segment geometry | all 6 | Traffic can't be joined to stops yet; the 500 m join is written and ready |
| Traffic volume is a sample | 432 rows | 6 synthetic segments over 3 days, flagged `is_mock_data` |
| DA coordinates | 1,105 bad | Flagged against each council's median point |
| Schools outside the study area | 1,133 of 2,210 | Source is NSW-wide; kept and flagged, not projected |
| Recent sale periods incomplete | last ~7 months | Late-published sales keep moving recent medians |
| Rent is LGA-level and tiny | 48 rows, 6 LGAs | Only 19.5% of stops carry a rent figure |
| Stop → LGA is inferred | 22,599 of 23,427 | No boundary polygons on disk; nearest-council heuristic used instead |

## License

MIT - see [LICENSE](LICENSE).
