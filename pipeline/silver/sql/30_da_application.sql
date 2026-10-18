-- silver.da_application - development applications, typed, placed and flagged.

CREATE TABLE IF NOT EXISTS silver.da_application (
    application_number       text        PRIMARY KEY,   -- PlanningPortalApplicationNumber
    council_application_number text,
    council_name             text,
    application_type         text,
    application_status       text,
    submission_date          date,
    lodgement_date           date,
    determination_date       date,
    date_last_updated        timestamptz,
    determination_authority  text,
    cost_of_development      numeric(16,2),
    number_of_new_dwellings  integer,
    number_of_storeys        integer,
    number_of_existing_lots  integer,
    number_of_proposed_lots  integer,
    days_to_determination    integer,
    suburb                   text,
    postcode                 text,
    full_address             text,
    geom                     geometry(Point, 4326),
    geom_m                   geometry(Point, 7856),     -- NULL unless inside the AOI
    hex_id                   text,
    flag_missing_coords      boolean     NOT NULL DEFAULT false,
    flag_outside_aoi         boolean     NOT NULL DEFAULT false,
    flag_bad_geocode         boolean     NOT NULL DEFAULT false,
    flag_geocode_collision   boolean     NOT NULL DEFAULT false,
    flag_cost_outlier        boolean     NOT NULL DEFAULT false,
    flag_date_order          boolean     NOT NULL DEFAULT false,
    is_usable                boolean     NOT NULL DEFAULT true,
    record_source            text        NOT NULL DEFAULT 'NSW_PLANNING_PORTAL_DA',
    loaded_at                timestamptz NOT NULL DEFAULT now()
);

-- One index per column we actually filter/join on downstream
CREATE INDEX IF NOT EXISTS da_application_hex_idx    ON silver.da_application (hex_id);
CREATE INDEX IF NOT EXISTS da_application_geom_m_idx ON silver.da_application USING gist (geom_m);
CREATE INDEX IF NOT EXISTS da_application_council_idx ON silver.da_application (council_name);
CREATE INDEX IF NOT EXISTS da_application_lodged_idx ON silver.da_application (lodgement_date);

INSERT INTO silver.da_application AS t
    (application_number, council_application_number, council_name, application_type,
     application_status, submission_date, lodgement_date, determination_date,
     date_last_updated, determination_authority, cost_of_development,
     number_of_new_dwellings, number_of_storeys, number_of_existing_lots,
     number_of_proposed_lots, days_to_determination, suburb, postcode, full_address,
     geom, geom_m, flag_missing_coords, flag_outside_aoi, flag_bad_geocode,
     flag_geocode_collision, flag_cost_outlier, flag_date_order, is_usable)
-- aoi: observed area, back to WGS84 transformed for comparison
WITH aoi AS (
    SELECT ST_Transform(geom_m, 4326) AS geom FROM silver.aoi
),
-- src: one clean row per request - Texte trim, postcode validation,
-- and swaped Lat/Lon- checking.
src AS (
    SELECT DISTINCT ON (b.planning_portal_application_number)
           b.planning_portal_application_number        AS application_number,
           nullif(trim(b.council_application_number), '') AS council_application_number,
           nullif(trim(b.council_name), '')            AS council_name,
           nullif(trim(b.application_type), '')        AS application_type,
           nullif(trim(b.application_status), '')      AS application_status,
           b.submission_date, b.lodgement_date, b.determination_date,
           b.date_last_updated,
           nullif(trim(b.determination_authority), '') AS determination_authority,
           b.cost_of_development,
           b.number_of_new_dwellings, b.number_of_storeys,
           b.number_of_existing_lots, b.number_of_proposed_lots,
           upper(nullif(trim(b.suburb), ''))           AS suburb,
           CASE WHEN trim(b.postcode) ~ '^[0-9]{4}$' THEN trim(b.postcode) END AS postcode,
           nullif(trim(b.full_address), '')            AS full_address,
           CASE WHEN b.latitude IS NOT NULL AND b.longitude IS NOT NULL
                     -- a positive latitude or negative longitude here means the
                     -- pair was swapped at the source; treat as no coordinate
                     AND b.latitude BETWEEN -90 AND 0 AND b.longitude BETWEEN 0 AND 180
                THEN ST_SetSRID(ST_MakePoint(b.longitude, b.latitude), 4326) END AS geom
      FROM bronze.da_applications b
     WHERE b.planning_portal_application_number IS NOT NULL
     ORDER BY b.planning_portal_application_number, b._loaded_at DESC
),
-- cost_bounds: the 0.1%- and 99.9%-Perzentile of construction costs, as extreme boundaries.
cost_bounds AS (
    SELECT percentile_cont(0.001) WITHIN GROUP (ORDER BY cost_of_development) AS lo,
           percentile_cont(0.999) WITHIN GROUP (ORDER BY cost_of_development) AS hi,
           count(*) AS n
      FROM src WHERE cost_of_development IS NOT NULL
),
-- council_centre: where councils requests are more than other councils (Median-point),
-- reference to detect geocoding errors.
council_centre AS (
    SELECT council_name,
           ST_SetSRID(ST_MakePoint(
               percentile_cont(0.5) WITHIN GROUP (ORDER BY ST_X(geom)),
               percentile_cont(0.5) WITHIN GROUP (ORDER BY ST_Y(geom))), 4326) AS centre
      FROM src
     WHERE geom IS NOT NULL AND council_name IS NOT NULL
     GROUP BY council_name
),
-- collisions: of the same exact points, used from 3+ request adresses
-- could be error .
collisions AS (
    SELECT geom
      FROM src
     WHERE geom IS NOT NULL
     GROUP BY geom
    HAVING count(*) >= 3 AND count(DISTINCT coalesce(full_address, '')) >= 3
),
-- scored: src with all four flag conditions (out of area,
-- not so good geo coding, collision, cost to much, date not correct).
scored AS (
    SELECT s.*,
           (s.geom IS NOT NULL AND ST_Intersects(s.geom, a.geom))      AS inside_aoi,
           (s.geom IS NOT NULL AND cc.centre IS NOT NULL
             AND ST_Distance(s.geom::geography, cc.centre::geography) > 50000)
                                                                       AS bad_geocode,
           (co.geom IS NOT NULL)                                       AS collision,
           (cb.n >= 100 AND s.cost_of_development IS NOT NULL
             AND (s.cost_of_development < cb.lo OR s.cost_of_development > cb.hi))
                                                                       AS cost_outlier,
           (coalesce(s.lodgement_date < s.submission_date, false)
             OR coalesce(s.determination_date < s.lodgement_date, false))               AS date_disorder
      FROM src s
      CROSS JOIN aoi a
      CROSS JOIN cost_bounds cb
      LEFT JOIN council_centre cc USING (council_name)
      LEFT JOIN collisions co ON co.geom = s.geom
)
SELECT application_number, council_application_number, council_name, application_type,
       application_status, submission_date, lodgement_date, determination_date,
       date_last_updated, determination_authority, cost_of_development,
       number_of_new_dwellings, number_of_storeys, number_of_existing_lots,
       number_of_proposed_lots,
       CASE WHEN determination_date IS NOT NULL AND lodgement_date IS NOT NULL
                 AND determination_date >= lodgement_date
            THEN determination_date - lodgement_date END,
       suburb, postcode, full_address,
       geom,
       CASE WHEN inside_aoi AND NOT bad_geocode THEN ST_Transform(geom, 7856) END,
       geom IS NULL,
       geom IS NOT NULL AND NOT inside_aoi,
       bad_geocode,
       collision,
       cost_outlier,
       coalesce(date_disorder, false),
       inside_aoi AND NOT bad_geocode AND NOT coalesce(date_disorder, false)
  FROM scored
ON CONFLICT (application_number) DO UPDATE
   SET application_status      = EXCLUDED.application_status,
       determination_date      = EXCLUDED.determination_date,
       date_last_updated       = EXCLUDED.date_last_updated,
       cost_of_development     = EXCLUDED.cost_of_development,
       number_of_new_dwellings = EXCLUDED.number_of_new_dwellings,
       number_of_storeys       = EXCLUDED.number_of_storeys,
       days_to_determination   = EXCLUDED.days_to_determination,
       geom                    = EXCLUDED.geom,
       geom_m                  = EXCLUDED.geom_m,
       flag_missing_coords     = EXCLUDED.flag_missing_coords,
       flag_outside_aoi        = EXCLUDED.flag_outside_aoi,
       flag_bad_geocode        = EXCLUDED.flag_bad_geocode,
       flag_geocode_collision  = EXCLUDED.flag_geocode_collision,
       flag_cost_outlier       = EXCLUDED.flag_cost_outlier,
       flag_date_order         = EXCLUDED.flag_date_order,
       is_usable               = EXCLUDED.is_usable,
       loaded_at               = now()
 WHERE (t.application_status, t.determination_date, t.cost_of_development,
        t.number_of_new_dwellings, t.is_usable)
       IS DISTINCT FROM
       (EXCLUDED.application_status, EXCLUDED.determination_date,
        EXCLUDED.cost_of_development, EXCLUDED.number_of_new_dwellings,
        EXCLUDED.is_usable);

UPDATE silver.da_application d
   SET hex_id = (SELECT min(h.hex_id) FROM silver.hex_300m h
                  WHERE d.geom_m IS NOT NULL AND ST_Covers(h.geom_m, d.geom_m));
