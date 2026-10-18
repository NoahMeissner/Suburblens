-- silver.bus_stop_traffic - traffic within 500 m of a bus stop.

CREATE TABLE IF NOT EXISTS silver.bus_stop_traffic (
    stop_id                   integer     NOT NULL REFERENCES silver.bus_stop ON DELETE CASCADE,
    daypart                   text        NOT NULL,
    daypart_kind              text        NOT NULL,
    n_segments_500m           integer     NOT NULL,
    avg_vehicles_per_hour     numeric(12,2),
    avg_vehicles_per_hour_idw numeric(12,2),
    max_vehicles_per_hour     integer,
    nearest_segment_id        text,
    nearest_segment_distance_m numeric(10,2),
    record_source             text        NOT NULL DEFAULT 'TFNSW_TRAFFIC_VOLUME_COUNTS',
    loaded_at                 timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT bus_stop_traffic_pkey PRIMARY KEY (stop_id, daypart)
);

-- Fully derived, so rebuild wholesale instead of trying to upsert this
DELETE FROM silver.bus_stop_traffic;

INSERT INTO silver.bus_stop_traffic
    (stop_id, daypart, daypart_kind, n_segments_500m, avg_vehicles_per_hour,
     avg_vehicles_per_hour_idw, max_vehicles_per_hour, nearest_segment_id,
     nearest_segment_distance_m)
-- near: every Stop connected with all Traffic-Segments in 500m, with distance.
WITH near AS (
    SELECT s.stop_id,
           t.segment_id,
           ST_Distance(s.geom_m, t.geom_m)::numeric AS distance_m
      FROM silver.bus_stop s
      JOIN silver.traffic_segment t
        ON ST_DWithin(s.geom_m, t.geom_m, 500)
     WHERE t.geom_m IS NOT NULL
)
-- per Stop and Daypart aggregated: once simple average, once with
-- Inverse-Distance-Weighting.
SELECT n.stop_id,
       d.daypart,
       d.daypart_kind,
       count(*)::integer,
       round(avg(d.avg_vehicles_per_hour), 2),
       round(sum(d.avg_vehicles_per_hour / greatest(n.distance_m, 1))
             / nullif(sum(1 / greatest(n.distance_m, 1)), 0), 2),
       max(d.max_vehicles_per_hour),
       (array_agg(n.segment_id ORDER BY n.distance_m, n.segment_id))[1],
       min(n.distance_m)
  FROM near n
  JOIN silver.traffic_segment_daypart d USING (segment_id)
 GROUP BY n.stop_id, d.daypart, d.daypart_kind;
