-- silver.bus_stop - the spine every other source is measured against.

CREATE TABLE IF NOT EXISTS silver.bus_stop (
    stop_id         integer     PRIMARY KEY,
    stop_name       text,
    routes_served   text[]      NOT NULL DEFAULT '{}',
    route_count     integer     NOT NULL DEFAULT 0,
    geom            geometry(Point, 4326) NOT NULL,
    geom_m          geometry(Point, 7856) NOT NULL,
    hex_id          text,       -- -> silver.hex_300m, set by 11_hex_300m.sql
    flag_no_service boolean     NOT NULL DEFAULT false,
    record_source   text        NOT NULL DEFAULT 'SYDNEY_BUS_STOPS_GEOJSON',
    loaded_at       timestamptz NOT NULL DEFAULT now()
);

-- GIST index for both geometries, because we query distance/intersects on both
CREATE INDEX IF NOT EXISTS bus_stop_geom_idx     ON silver.bus_stop USING gist (geom);
CREATE INDEX IF NOT EXISTS bus_stop_geom_m_idx   ON silver.bus_stop USING gist (geom_m);
-- Plain index so "which stops are in this hex" stays fast
CREATE INDEX IF NOT EXISTS bus_stop_hex_idx      ON silver.bus_stop (hex_id);

INSERT INTO silver.bus_stop AS t
    (stop_id, stop_name, routes_served, route_count, geom, geom_m, flag_no_service)
-- src: one row per Stop from Bronze - Name trimmed, route-Array 
-- JSON extracted and double name deleted, only real geometry stays
WITH src AS (
    SELECT DISTINCT ON (b.stop_id)
           b.stop_id,
           nullif(trim(b.name), '')                            AS stop_name,
           COALESCE(
               (SELECT array_agg(DISTINCT trim(r))
                  FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(b.routes_served)='array' THEN b.routes_served ELSE '[]'::jsonb END) AS r
                 WHERE nullif(trim(r), '') IS NOT NULL),
               '{}')                                           AS routes_served,
           silver.safe_geometry(b.geometry)     AS geom
      FROM bronze.bus_stops b
     WHERE b.stop_id IS NOT NULL
       AND b.geometry IS NOT NULL
       AND silver.safe_geometry(b.geometry) IS NOT NULL
       AND b.geometry ->> 'type' = 'Point'
     ORDER BY b.stop_id, b._loaded_at DESC          -- on duplicates the newest wins
),
-- served: alle stop_ids, with at least one Bus-edge in the graph
served AS (
    SELECT DISTINCT from_stop_id AS stop_id FROM bronze.bus_graph_edges
                                            WHERE from_stop_id IS NOT NULL
    UNION
    SELECT DISTINCT to_stop_id   AS stop_id FROM bronze.bus_graph_edges
                                            WHERE to_stop_id IS NOT NULL
)
-- Every Stop from src, marks with flag_no_service = true, if he misse
SELECT s.stop_id,
       s.stop_name,
       s.routes_served,
       cardinality(s.routes_served),
       s.geom,
       ST_Transform(s.geom, 7856),
       (e.stop_id IS NULL)
  FROM src s
  LEFT JOIN served e USING (stop_id)
ON CONFLICT (stop_id) DO UPDATE
   SET stop_name       = EXCLUDED.stop_name,
       routes_served   = EXCLUDED.routes_served,
       route_count     = EXCLUDED.route_count,
       geom            = EXCLUDED.geom,
       geom_m          = EXCLUDED.geom_m,
       flag_no_service = EXCLUDED.flag_no_service,
       loaded_at       = now()
 WHERE (t.stop_name, t.routes_served, t.route_count, t.flag_no_service)
       IS DISTINCT FROM
       (EXCLUDED.stop_name, EXCLUDED.routes_served, EXCLUDED.route_count,
        EXCLUDED.flag_no_service)
    OR NOT ST_Equals(t.geom, EXCLUDED.geom);

-- The observed area, from the stops instead of getting it from hard coded ruels. 
-- 2 km Puffer outside the convex hull.
CREATE MATERIALIZED VIEW IF NOT EXISTS silver.aoi AS
SELECT ST_Buffer(ST_ConvexHull(ST_Collect(geom_m)), 2000) AS geom_m,
       count(*)                                           AS n_stops
  FROM silver.bus_stop;

REFRESH MATERIALIZED VIEW silver.aoi;
