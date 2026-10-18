"""Suburb-level statistics and rankings for the overview page."""
from dataclasses import dataclass
from functools import lru_cache

from web.db import postgres

SUBURB_RADIUS_M = 800
"""How far around a suburb's street centroid counts as "that suburb", for the
bus-activity proxy. Arbitrary but fixed - there is no boundary to measure
against instead."""

TOP_N = 10

_QUERY = """
WITH centroids AS (
    SELECT locality, ST_Centroid(ST_Collect(centroid_m)) AS centroid_m
      FROM silver.street_locality
     WHERE centroid_m IS NOT NULL
     GROUP BY locality
), schools AS (
    SELECT town_suburb AS locality, count(*)::integer AS n_schools
      FROM silver.school
     WHERE town_suburb IS NOT NULL
     GROUP BY 1
), das AS (
    SELECT suburb AS locality, count(*)::integer AS n_da
      FROM silver.da_application
     WHERE suburb IS NOT NULL AND is_usable
     GROUP BY 1
), activity AS (
    -- the same proxy as web.report's _activity, summed around the suburb
    -- centroid instead of an address point
    SELECT c.locality,
           coalesce(sum(t.trips_per_day), 0)::integer AS trips_per_day,
           count(t.*)::integer                        AS n_segments
      FROM centroids c
      LEFT JOIN gold.transit_segment t
             ON NOT t.flag_long_segment
            AND ST_DWithin(t.geom_m, c.centroid_m, %s)
     GROUP BY c.locality
)
SELECT c.locality, sc.lga_name,
       sc.median_price, sc.rank_median_price, coalesce(sc.n_ranked, 0),
       coalesce(a.trips_per_day, 0), coalesce(a.n_segments, 0),
       coalesce(s.n_schools, 0), coalesce(d.n_da, 0)
  FROM centroids c
  LEFT JOIN gold.suburb_comparison sc USING (locality)
  LEFT JOIN activity a USING (locality)
  LEFT JOIN schools  s USING (locality)
  LEFT JOIN das      d USING (locality)
"""


@dataclass(frozen=True)
class SuburbStat:  # pylint: disable=too-many-instance-attributes
    """One suburb and every figure measured around it."""
    locality: str
    lga_name: str | None
    median_price: float | None
    price_rank: int | None
    n_ranked_price: int
    trips_per_day: int
    n_segments_nearby: int
    n_schools: int
    n_da_applications: int


@dataclass(frozen=True)
class Highlight:
    """The rank-1 fact for one start-page tile: a suburb, what the number
    measures, and the number itself - in that order, so the number is never
    shown without saying what it counts."""
    locality: str
    metric_label: str
    value: str
    context: str


@dataclass(frozen=True)
class RankedSuburb:
    """One row of a /rankings top-10 list."""
    rank: int
    locality: str
    value: str


@dataclass(frozen=True)
class Overview:  # pylint: disable=too-many-instance-attributes
    """Five start-page tiles, and the five top-10 lists behind /rankings."""
    most_expensive: Highlight | None
    quietest: Highlight | None
    most_schools: Highlight | None
    most_applications: Highlight | None
    fewest_applications: Highlight | None
    top_expensive: list[RankedSuburb]
    top_quietest: list[RankedSuburb]
    top_schools: list[RankedSuburb]
    top_applications: list[RankedSuburb]
    bottom_applications: list[RankedSuburb]
    n_suburbs: int


@lru_cache(maxsize=1)
def suburbs() -> tuple[SuburbStat, ...]:
    """Every suburb with a geocoded street, and the figures around it.

    Cached for the life of the process: this is warehouse-wide data that only
    changes when the pipeline reloads, never per request.
    """
    with postgres() as conn:
        rows = conn.execute(_QUERY, [SUBURB_RADIUS_M]).fetchall()
    return tuple(
        SuburbStat(
            locality=row[0], lga_name=row[1],
            median_price=float(row[2]) if row[2] is not None else None,
            price_rank=row[3], n_ranked_price=row[4],
            trips_per_day=row[5], n_segments_nearby=row[6],
            n_schools=row[7], n_da_applications=row[8],
        )
        for row in rows
    )


def _money(value: float) -> str:
    return f"${value:,.0f}"


def _ranked(rows, value_fn, formatted_fn) -> list[RankedSuburb]:
    """The top TOP_N rows, already sorted by the caller, as display rows."""
    return [
        RankedSuburb(rank=i, locality=r.locality, value=formatted_fn(value_fn(r)))
        for i, r in enumerate(rows[:TOP_N], start=1)
    ]


def overview() -> Overview:
    """The five start-page tiles, and the five /rankings top-10 lists."""
    rows = suburbs()

    by_price = sorted((r for r in rows if r.price_rank is not None),
                       key=lambda r: r.price_rank)
    with_activity = sorted((r for r in rows if r.n_segments_nearby > 0),
                            key=lambda r: r.trips_per_day)
    by_schools = sorted((r for r in rows if r.n_schools > 0),
                         key=lambda r: r.n_schools, reverse=True)
    with_da = [r for r in rows if r.n_da_applications > 0]
    most_da = sorted(with_da, key=lambda r: r.n_da_applications, reverse=True)
    fewest_da = sorted(with_da, key=lambda r: r.n_da_applications)

    top_expensive = _ranked(by_price, lambda r: r.median_price, _money)
    top_quietest = _ranked(with_activity, lambda r: r.trips_per_day,
                            lambda v: f"{v}/day")
    top_schools = _ranked(by_schools, lambda r: r.n_schools, str)
    top_applications = _ranked(most_da, lambda r: r.n_da_applications, str)
    bottom_applications = _ranked(fewest_da, lambda r: r.n_da_applications, str)

    n_ranked_price = rows[0].n_ranked_price if rows else 0

    return Overview(
        most_expensive=Highlight(
            by_price[0].locality, "Median price", _money(by_price[0].median_price),
            f"rank 1 of {n_ranked_price} ranked suburbs",
        ) if by_price else None,
        quietest=Highlight(
            with_activity[0].locality, "Bus trips/day nearby",
            str(with_activity[0].trips_per_day),
            f"within {SUBURB_RADIUS_M} m of the suburb centre - a proxy, not a "
            "noise measurement",
        ) if with_activity else None,
        most_schools=Highlight(
            by_schools[0].locality, "Schools", str(by_schools[0].n_schools),
            "the most of any suburb in this data",
        ) if by_schools else None,
        most_applications=Highlight(
            most_da[0].locality, "Development applications",
            str(most_da[0].n_da_applications),
            f"of {len(with_da)} suburbs with at least one",
        ) if most_da else None,
        fewest_applications=Highlight(
            fewest_da[0].locality, "Development applications",
            str(fewest_da[0].n_da_applications),
            f"of {len(with_da)} suburbs with at least one",
        ) if fewest_da else None,
        top_expensive=top_expensive,
        top_quietest=top_quietest,
        top_schools=top_schools,
        top_applications=top_applications,
        bottom_applications=bottom_applications,
        n_suburbs=len(rows),
    )
