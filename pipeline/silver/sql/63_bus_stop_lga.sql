-- silver.bus_stop_lga - which LGA each bus stop sits in.
--
-- No LGA boundary polygons exist on disk, so the boundary is inferred from the
-- data that does: usable DA applications, each carrying both a
-- coordinate and its own council_name. The LGA of a stop is the council that
-- MOST of the DA applications within 1 km belong to.
--
CREATE TABLE IF NOT EXISTS silver.bus_stop_lga (
    stop_id               integer     PRIMARY KEY REFERENCES silver.bus_stop ON DELETE CASCADE,
    lga_code              text        NOT NULL REFERENCES silver.lga,
    assignment_method     text        NOT NULL,   -- 'da_majority_1km' | 'da_nearest'
    n_da_points           integer     NOT NULL,
    nearest_da_distance_m numeric(10,2),
    flag_low_confidence   boolean     NOT NULL DEFAULT false,
    record_source         text        NOT NULL DEFAULT 'INFERRED_FROM_DA_COUNCIL',
    loaded_at             timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT bus_stop_lga_method_check
        CHECK (assignment_method IN ('da_majority_1km', 'da_nearest'))
);

-- Index on lga_code for the "all stops in this LGA" direction
CREATE INDEX IF NOT EXISTS bus_stop_lga_lga_idx ON silver.bus_stop_lga (lga_code);

DELETE FROM silver.bus_stop_lga;

INSERT INTO silver.bus_stop_lga
    (stop_id, lga_code, assignment_method, n_da_points, nearest_da_distance_m,
     flag_low_confidence)
-- tally: per Stop and LGA count, with many DA-Requests in range of 1km,
-- + the distance to the next of each other.
WITH tally AS (
    SELECT s.stop_id,
           silver.lga_key(d.council_name)              AS lga_code,
           count(*)::integer                           AS n_da_points,
           min(ST_Distance(s.geom_m, d.geom_m))::numeric AS nearest_m
      FROM silver.bus_stop s
      JOIN silver.da_application d
        ON ST_DWithin(s.geom_m, d.geom_m, 1000)
     WHERE d.is_usable
       AND d.council_name IS NOT NULL
     GROUP BY s.stop_id, silver.lga_key(d.council_name)
),
-- majority: per Stop the LGA with the most requests contain, together with the 
-- percentage, of the majority of all requests in 1km distance
majority AS (
    SELECT DISTINCT ON (stop_id)
           stop_id, lga_code, n_da_points, nearest_m,
           -- share of the 1 km neighbourhood that agreed with the winner
           n_da_points::numeric
             / sum(n_da_points) OVER (PARTITION BY stop_id) AS winner_share
      FROM tally
     ORDER BY stop_id, n_da_points DESC, nearest_m
),
-- fallback: for Stops without any unique DA-request in 1km-radius - take next reqeust 
fallback AS (
    SELECT s.stop_id,
           n.lga_code,
           n.nearest_m
      FROM silver.bus_stop s
      CROSS JOIN LATERAL (
          SELECT silver.lga_key(d.council_name)                AS lga_code,
                 ST_Distance(s.geom_m, d.geom_m)::numeric      AS nearest_m
            FROM silver.da_application d
           WHERE d.is_usable AND d.council_name IS NOT NULL
           ORDER BY d.geom_m <-> s.geom_m
           LIMIT 1) n
     WHERE NOT EXISTS (SELECT 1 FROM majority m WHERE m.stop_id = s.stop_id)
       AND n.nearest_m <= 5000      -- beyond this it is a guess, not a fallback
)
SELECT stop_id, lga_code, 'da_majority_1km', n_da_points, round(nearest_m, 2),
       (n_da_points < 10 OR nearest_m > 500 OR winner_share < 0.6)
  FROM majority
UNION ALL
SELECT stop_id, lga_code, 'da_nearest', 1, round(nearest_m, 2), true
  FROM fallback;
