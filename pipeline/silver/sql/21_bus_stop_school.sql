-- silver.bus_stop_school - schools near a stop, many-to-many.

CREATE TABLE IF NOT EXISTS silver.bus_stop_school (
    stop_id          integer       NOT NULL REFERENCES silver.bus_stop   ON DELETE CASCADE,
    school_code      integer       NOT NULL REFERENCES silver.school     ON DELETE CASCADE,
    radius_m         smallint      NOT NULL,
    distance_m       numeric(8,2)  NOT NULL,
    rank_from_stop   integer       NOT NULL,   -- 1 = this stop's closest school
    rank_from_school integer       NOT NULL,   -- 1 = this school's closest stop
    record_source    text          NOT NULL DEFAULT 'SCHOOL_X_BUS_STOP_PROXIMITY',
    loaded_at        timestamptz   NOT NULL DEFAULT now(),

    CONSTRAINT bus_stop_school_pkey PRIMARY KEY (radius_m, stop_id, school_code),
    CONSTRAINT bus_stop_school_radius_check CHECK (radius_m IN (200, 300))
);

-- Reverse-direction index: "which stops are near this school" needs this too
CREATE INDEX IF NOT EXISTS bus_stop_school_school_idx
    ON silver.bus_stop_school (school_code, radius_m);

-- Derived join: rebuild wholesale inside the step's transaction.
DELETE FROM silver.bus_stop_school;

INSERT INTO silver.bus_stop_school
    (stop_id, school_code, radius_m, distance_m, rank_from_stop, rank_from_school)
-- pairs: every Stop-school-pair in 300m, once calculated. the 200m-Radius
-- is only one filter instead of a nother calculation
WITH pairs AS (
    SELECT st.stop_id,
           sc.school_code,
           ST_Distance(st.geom_m, sc.geom_m)::numeric AS distance_m
      FROM silver.bus_stop st
      JOIN silver.school   sc
        ON ST_DWithin(st.geom_m, sc.geom_m, 300)
     WHERE sc.is_usable
),
-- banded: the pairs once with 300m radius and filtered with 200m radius,
-- that both radiuses are in the same table.
banded AS (
    SELECT stop_id, school_code, distance_m, 300 AS radius_m FROM pairs
    UNION ALL
    SELECT stop_id, school_code, distance_m, 200 FROM pairs WHERE distance_m <= 200
)
SELECT stop_id,
       school_code,
       radius_m,
       round(distance_m, 2),
       rank() OVER (PARTITION BY radius_m, stop_id     ORDER BY distance_m, school_code),
       rank() OVER (PARTITION BY radius_m, school_code ORDER BY distance_m, stop_id)
  FROM banded;

-- Per-stop roll-up at the requested 200 m, so the profile table is a plain join.
CREATE TABLE IF NOT EXISTS silver.bus_stop_school_summary (
    stop_id                   integer     PRIMARY KEY REFERENCES silver.bus_stop ON DELETE CASCADE,
    n_schools_200m            integer     NOT NULL,
    nearest_school_code       integer,
    nearest_school_distance_m numeric(8,2),
    sum_enrolment_fte_200m    numeric(12,1),
    avg_icsea_200m            numeric(8,2),
    has_primary               boolean     NOT NULL DEFAULT false,
    has_secondary             boolean     NOT NULL DEFAULT false,
    record_source             text        NOT NULL DEFAULT 'SCHOOL_X_BUS_STOP_PROXIMITY',
    loaded_at                 timestamptz NOT NULL DEFAULT now()
);

DELETE FROM silver.bus_stop_school_summary;

INSERT INTO silver.bus_stop_school_summary
    (stop_id, n_schools_200m, nearest_school_code, nearest_school_distance_m,
     sum_enrolment_fte_200m, avg_icsea_200m, has_primary, has_secondary)
SELECT b.stop_id,
       count(*)::integer,
       (array_agg(s.school_code ORDER BY b.distance_m, s.school_code))[1],
       min(b.distance_m),
       sum(s.latest_year_enrolment_fte),
       round(avg(s.icsea_value), 2),
       bool_or(s.level_of_schooling ILIKE '%primary%'
               OR s.level_of_schooling ILIKE '%infants%'
               OR s.level_of_schooling ILIKE '%central%'),
       bool_or(s.level_of_schooling ILIKE '%secondary%'
               OR s.level_of_schooling ILIKE '%central%')
  FROM silver.bus_stop_school b
  JOIN silver.school s USING (school_code)
 WHERE b.radius_m = 200
 GROUP BY b.stop_id;
