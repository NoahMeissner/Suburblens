-- silver.bus_edge - one row per LOGICAL stop-to-stop edge.

CREATE TABLE IF NOT EXISTS silver.bus_edge (
    edge_key         text        PRIMARY KEY,
    from_stop_id     integer     NOT NULL REFERENCES silver.bus_stop,
    to_stop_id       integer     NOT NULL REFERENCES silver.bus_stop,
    route_id         text        NOT NULL,
    route_short_name text,
    direction_id     smallint    NOT NULL,
    geom             geometry(LineString, 4326) NOT NULL,
    geom_m           geometry(LineString, 7856) NOT NULL,
    straight_line_m  numeric(12,2) NOT NULL,
    n_source_rows    integer     NOT NULL,
    record_source    text        NOT NULL DEFAULT 'SYDNEY_BUS_GRAPH_EDGES_GEOJSON',
    loaded_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT bus_edge_business_key UNIQUE (from_stop_id, to_stop_id, route_id, direction_id),
    CONSTRAINT bus_edge_no_self_loop CHECK (from_stop_id <> to_stop_id),
    CONSTRAINT bus_edge_direction_check CHECK (direction_id IN (0, 1))
);

-- Index both ends of the edge, so "which edges touch this stop" is cheap either way
CREATE INDEX IF NOT EXISTS bus_edge_from_idx   ON silver.bus_edge (from_stop_id);
CREATE INDEX IF NOT EXISTS bus_edge_to_idx     ON silver.bus_edge (to_stop_id);
CREATE INDEX IF NOT EXISTS bus_edge_geom_m_idx ON silver.bus_edge USING gist (geom_m);

INSERT INTO silver.bus_edge AS t
    (edge_key, from_stop_id, to_stop_id, route_id, route_short_name, direction_id,
     geom, geom_m, straight_line_m, n_source_rows)
-- usable: only Bronze-edges, die auf zwei echte, bekannte Stops zeigen und eine
-- usable: only Bronze-edges, which look on two real stops and have a real line geometry
WITH usable AS (
    SELECT e.*,
           silver.safe_geometry(e.geometry) AS geom
      FROM bronze.bus_graph_edges e
     WHERE e.from_stop_id IS NOT NULL
       AND e.to_stop_id   IS NOT NULL
       AND e.from_stop_id <> e.to_stop_id
       AND e.route_id     IS NOT NULL
       AND e.direction_id IS NOT NULL
       AND silver.safe_geometry(e.geometry) IS NOT NULL
       AND e.geometry ->> 'type' = 'LineString'
       AND EXISTS (SELECT 1 FROM silver.bus_stop s WHERE s.stop_id = e.from_stop_id)
       AND EXISTS (SELECT 1 FROM silver.bus_stop s WHERE s.stop_id = e.to_stop_id)
),
-- grouped: more Bronze-rows with the same two endpoints (Trip-possibilites)
-- will be combined to logical one; Geometry comes deterministic
-- with the variant with the samllest edge_id.
grouped AS (
    SELECT from_stop_id, to_stop_id, route_id, direction_id,
           min(route_short_name)                       AS route_short_name,
           count(*)                                    AS n_source_rows,
           -- the variants share the same two endpoints, so any member's line
           -- is the edge's line; pick deterministically by lowest edge_id
           (array_agg(geom ORDER BY edge_id))[1]       AS geom
      FROM usable
     GROUP BY from_stop_id, to_stop_id, route_id, direction_id
)
SELECT md5(from_stop_id || '||' || to_stop_id || '||' || route_id || '||' || direction_id),
       from_stop_id, to_stop_id, route_id, route_short_name, direction_id,
       geom,
       ST_Transform(geom, 7856),
       ST_Length(ST_Transform(geom, 7856)),
       n_source_rows
  FROM grouped
ON CONFLICT (edge_key) DO UPDATE
   SET route_short_name = EXCLUDED.route_short_name,
       geom             = EXCLUDED.geom,
       geom_m           = EXCLUDED.geom_m,
       straight_line_m  = EXCLUDED.straight_line_m,
       n_source_rows    = EXCLUDED.n_source_rows,
       loaded_at        = now()
 WHERE (t.route_short_name, t.straight_line_m, t.n_source_rows)
       IS DISTINCT FROM
       (EXCLUDED.route_short_name, EXCLUDED.straight_line_m, EXCLUDED.n_source_rows);

-- Lineage: which raw features were folded into each logical edge. Without this
-- source feature, for tracing deduplication.
CREATE TABLE IF NOT EXISTS silver.bus_edge_source (
    edge_key text    NOT NULL REFERENCES silver.bus_edge ON DELETE CASCADE,
    edge_id  integer NOT NULL,              -- bronze.bus_graph_edges.edge_id
    CONSTRAINT bus_edge_source_pkey PRIMARY KEY (edge_id)
);

-- Index on edge_key so looking up "which raw rows made this edge" is fast
CREATE INDEX IF NOT EXISTS bus_edge_source_edge_key_idx
    ON silver.bus_edge_source (edge_key);

-- For each raw Bronze-edge, in which logical edges are part
INSERT INTO silver.bus_edge_source (edge_key, edge_id)
SELECT md5(e.from_stop_id || '||' || e.to_stop_id || '||' || e.route_id || '||' || e.direction_id),
       e.edge_id
  FROM bronze.bus_graph_edges e
 WHERE silver.safe_geometry(e.geometry) IS NOT NULL
   AND e.geometry->>'type'='LineString'
   AND e.direction_id IN (0,1)
   AND EXISTS (SELECT 1 FROM silver.bus_edge b
                WHERE b.edge_key = md5(e.from_stop_id || '||' || e.to_stop_id
                                       || '||' || e.route_id || '||' || e.direction_id))
ON CONFLICT (edge_id) DO NOTHING;
