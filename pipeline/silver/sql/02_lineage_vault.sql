-- Hub = Table with Buisness Key (stop_id) + additional artificial hub_key
-- Satellite = one row per raw dataset with whole payload and reference to the hub.
-- Every of the 7 sections is doing pretty much the same, Create Hub Table, fill up hub from bronze,
-- Create Satellite Table, Fill it with bronze
--
-- Satellite raw_id foreign keys are ON DELETE CASCADE: reloading a file in
-- bronze replaces its raw_record rows, and the satellite rows copied from them
-- have to go with them. The next silver run copies the new raw rows back in.


-- 1. bus_stop 
-- Hub: on row per stop_id. 
CREATE TABLE IF NOT EXISTS silver.hub_bus_stop (
    hub_key       text        PRIMARY KEY,
    stop_id       integer     NOT NULL,
    load_date     timestamptz NOT NULL DEFAULT now(),
    record_source text        NOT NULL DEFAULT 'SYDNEY_BUS_STOPS_GEOJSON'
);

INSERT INTO silver.hub_bus_stop (hub_key, stop_id)
SELECT DISTINCT md5(stop_id::text), stop_id -- md5 creates digital fingerprint
  FROM bronze.bus_stops
 WHERE stop_id IS NOT NULL
ON CONFLICT (hub_key) DO NOTHING;

-- Satellite -> one row per loaded dataset.
CREATE TABLE IF NOT EXISTS silver.sat_bus_stop (
    raw_id        bigint      PRIMARY KEY REFERENCES bronze.raw_record(raw_id) ON DELETE CASCADE,
    hub_key       text        REFERENCES silver.hub_bus_stop(hub_key),
    load_date     timestamptz NOT NULL,
    hash_diff     text        NOT NULL,
    load_status   text        NOT NULL CHECK (load_status IN ('accepted', 'rejected', 'duplicate')),
    payload       jsonb       NOT NULL,
    record_source text        NOT NULL DEFAULT 'SYDNEY_BUS_STOPS_GEOJSON'
);
CREATE INDEX IF NOT EXISTS sat_bus_stop_hub_load_idx ON silver.sat_bus_stop (hub_key, load_date);

INSERT INTO silver.sat_bus_stop (raw_id, hub_key, load_date, hash_diff, load_status, payload)
SELECT rr.raw_id, h.hub_key, b._loaded_at, md5(rr.payload::text), rr.load_status, rr.payload
  FROM bronze.raw_record rr
  JOIN bronze.ingest_file f ON f.source_file = rr.source_file
  JOIN bronze.bus_stops b ON b._raw_record_id = rr.raw_id
  LEFT JOIN silver.hub_bus_stop h ON h.hub_key = md5(b.stop_id::text)
 WHERE f.source_name = 'bus_stops'
ON CONFLICT (raw_id) DO NOTHING;

-- 2. bus_route (the one GTFS source with real shape-variant history)
-- Hub: one route per pro route_id+direction_id. 
-- Here we have more versions, because different routes. That's why every satellite row survives instead of collapsing to one per key.
CREATE TABLE IF NOT EXISTS silver.hub_route (
    hub_key       text        PRIMARY KEY,
    route_id      text        NOT NULL,
    direction_id  smallint    NOT NULL,
    load_date     timestamptz NOT NULL DEFAULT now(),
    record_source text        NOT NULL DEFAULT 'SYDNEY_BUS_ROUTES_GEOJSON'
);

INSERT INTO silver.hub_route (hub_key, route_id, direction_id)
SELECT DISTINCT md5(route_id || '|' || coalesce(direction_id, 0)::text),
       route_id, coalesce(direction_id, 0)
  FROM bronze.bus_routes
 WHERE route_id IS NOT NULL
ON CONFLICT (hub_key) DO NOTHING;

CREATE TABLE IF NOT EXISTS silver.sat_bus_route (
    raw_id        bigint      PRIMARY KEY REFERENCES bronze.raw_record(raw_id) ON DELETE CASCADE,
    hub_key       text        REFERENCES silver.hub_route(hub_key),
    load_date     timestamptz NOT NULL,
    hash_diff     text        NOT NULL,
    load_status   text        NOT NULL CHECK (load_status IN ('accepted', 'rejected', 'duplicate')),
    payload       jsonb       NOT NULL,
    record_source text        NOT NULL DEFAULT 'SYDNEY_BUS_ROUTES_GEOJSON'
);
CREATE INDEX IF NOT EXISTS sat_bus_route_hub_load_idx ON silver.sat_bus_route (hub_key, load_date);

INSERT INTO silver.sat_bus_route (raw_id, hub_key, load_date, hash_diff, load_status, payload)
SELECT rr.raw_id, h.hub_key, b._loaded_at, md5(rr.payload::text), rr.load_status, rr.payload
  FROM bronze.raw_record rr
  JOIN bronze.ingest_file f ON f.source_file = rr.source_file
  JOIN bronze.bus_routes b ON b._raw_record_id = rr.raw_id
  LEFT JOIN silver.hub_route h
         ON h.hub_key = md5(b.route_id || '|' || coalesce(b.direction_id, 0)::text)
 WHERE f.source_name = 'bus_routes'
ON CONFLICT (raw_id) DO NOTHING;

-- 3. school
-- Hub: 1 row per school id same structure as in bus stops

CREATE TABLE IF NOT EXISTS silver.hub_school (
    hub_key       text        PRIMARY KEY,
    school_code   integer     NOT NULL,
    load_date     timestamptz NOT NULL DEFAULT now(),
    record_source text        NOT NULL DEFAULT 'NSW_DOE_SCHOOL_LOCATIONS'
);

INSERT INTO silver.hub_school (hub_key, school_code)
SELECT DISTINCT md5(school_code::text), school_code
  FROM bronze.school_location
 WHERE school_code IS NOT NULL
ON CONFLICT (hub_key) DO NOTHING;

CREATE TABLE IF NOT EXISTS silver.sat_school (
    raw_id        bigint      PRIMARY KEY REFERENCES bronze.raw_record(raw_id) ON DELETE CASCADE,
    hub_key       text        REFERENCES silver.hub_school(hub_key),
    load_date     timestamptz NOT NULL,
    hash_diff     text        NOT NULL,
    load_status   text        NOT NULL CHECK (load_status IN ('accepted', 'rejected', 'duplicate')),
    payload       jsonb       NOT NULL,
    record_source text        NOT NULL DEFAULT 'NSW_DOE_SCHOOL_LOCATIONS'
);
CREATE INDEX IF NOT EXISTS sat_school_hub_load_idx ON silver.sat_school (hub_key, load_date);

INSERT INTO silver.sat_school (raw_id, hub_key, load_date, hash_diff, load_status, payload)
SELECT rr.raw_id, h.hub_key, b._loaded_at, md5(rr.payload::text), rr.load_status, rr.payload
  FROM bronze.raw_record rr
  JOIN bronze.ingest_file f ON f.source_file = rr.source_file
  JOIN bronze.school_location b ON b._raw_record_id = rr.raw_id
  LEFT JOIN silver.hub_school h ON h.hub_key = md5(b.school_code::text)
 WHERE f.source_name = 'school_location'
ON CONFLICT (raw_id) DO NOTHING;

-- 3. da_application 
-- Hub: one row per planning_portal_application_number, same pattern as in bus stop
CREATE TABLE IF NOT EXISTS silver.hub_da_application (
    hub_key                              text        PRIMARY KEY,
    planning_portal_application_number  text        NOT NULL,
    load_date                           timestamptz NOT NULL DEFAULT now(),
    record_source                       text        NOT NULL DEFAULT 'NSW_PLANNING_PORTAL_DA'
);

INSERT INTO silver.hub_da_application (hub_key, planning_portal_application_number)
SELECT DISTINCT md5(planning_portal_application_number), planning_portal_application_number
  FROM bronze.da_applications
 WHERE planning_portal_application_number IS NOT NULL
ON CONFLICT (hub_key) DO NOTHING;

CREATE TABLE IF NOT EXISTS silver.sat_da_application (
    raw_id        bigint      PRIMARY KEY REFERENCES bronze.raw_record(raw_id) ON DELETE CASCADE,
    hub_key       text        REFERENCES silver.hub_da_application(hub_key),
    load_date     timestamptz NOT NULL,
    hash_diff     text        NOT NULL,
    load_status   text        NOT NULL CHECK (load_status IN ('accepted', 'rejected', 'duplicate')),
    payload       jsonb       NOT NULL,
    record_source text        NOT NULL DEFAULT 'NSW_PLANNING_PORTAL_DA'
);
CREATE INDEX IF NOT EXISTS sat_da_application_hub_load_idx ON silver.sat_da_application (hub_key, load_date);

INSERT INTO silver.sat_da_application (raw_id, hub_key, load_date, hash_diff, load_status, payload)
SELECT rr.raw_id, h.hub_key, b._loaded_at, md5(rr.payload::text), rr.load_status, rr.payload
  FROM bronze.raw_record rr
  JOIN bronze.ingest_file f ON f.source_file = rr.source_file
  JOIN bronze.da_applications b ON b._raw_record_id = rr.raw_id
  LEFT JOIN silver.hub_da_application h
         ON h.hub_key = md5(b.planning_portal_application_number)
 WHERE f.source_name = 'da_applications'
ON CONFLICT (raw_id) DO NOTHING;

-- 4. property_parcel (the other source with real version history)
-- Hub: one row per dealing_number+parcel_seq. AS bus_route we have here
-- Source real Version Control, the load_date decides, what is current.

CREATE TABLE IF NOT EXISTS silver.hub_property_parcel (
    hub_key        text        PRIMARY KEY,
    dealing_number text        NOT NULL,
    parcel_seq     smallint    NOT NULL,
    load_date      timestamptz NOT NULL DEFAULT now(),
    record_source  text        NOT NULL DEFAULT 'NSW_VG_PROPERTY_SALES'
);

INSERT INTO silver.hub_property_parcel (hub_key, dealing_number, parcel_seq)
SELECT DISTINCT md5(dealing_number || '||' || parcel_seq::text), dealing_number, parcel_seq
  FROM bronze.property_sales
 WHERE dealing_number IS NOT NULL AND parcel_seq IS NOT NULL
ON CONFLICT (hub_key) DO NOTHING;

CREATE TABLE IF NOT EXISTS silver.sat_property_sales (
    raw_id        bigint      PRIMARY KEY REFERENCES bronze.raw_record(raw_id) ON DELETE CASCADE,
    hub_key       text        REFERENCES silver.hub_property_parcel(hub_key),
    load_date     timestamptz NOT NULL,
    hash_diff     text        NOT NULL,
    load_status   text        NOT NULL CHECK (load_status IN ('accepted', 'rejected', 'duplicate')),
    payload       jsonb       NOT NULL,
    record_source text        NOT NULL DEFAULT 'NSW_VG_PROPERTY_SALES'
);
CREATE INDEX IF NOT EXISTS sat_property_sales_hub_load_idx ON silver.sat_property_sales (hub_key, load_date);

-- load_date prefers the source's own versioning timestamp: within one bronze
-- COPY batch _loaded_at is identical across rows, so it cannot order
-- versions the way last_seen/load_from (or, failing those, raw_id) can.
INSERT INTO silver.sat_property_sales (raw_id, hub_key, load_date, hash_diff, load_status, payload)
SELECT rr.raw_id, h.hub_key, coalesce(b.last_seen, b.load_from, b._loaded_at),
       md5(rr.payload::text), rr.load_status, rr.payload
  FROM bronze.raw_record rr
  JOIN bronze.ingest_file f ON f.source_file = rr.source_file
  JOIN bronze.property_sales b ON b._raw_record_id = rr.raw_id
  LEFT JOIN silver.hub_property_parcel h
         ON h.hub_key = md5(b.dealing_number || '||' || b.parcel_seq::text)
 WHERE f.source_name = 'property_sales'
ON CONFLICT (raw_id) DO NOTHING;

-- 5. rent_observation
-- Hub: one row per rent_id, same pattern as bus_stop.

CREATE TABLE IF NOT EXISTS silver.hub_rent_observation (
    hub_key       text        PRIMARY KEY,
    rent_id       integer     NOT NULL,
    load_date     timestamptz NOT NULL DEFAULT now(),
    record_source text        NOT NULL DEFAULT 'NSW_RENT_BONDS'
);

INSERT INTO silver.hub_rent_observation (hub_key, rent_id)
SELECT DISTINCT md5(rent_id::text), rent_id
  FROM bronze.rent_data
 WHERE rent_id IS NOT NULL
ON CONFLICT (hub_key) DO NOTHING;

CREATE TABLE IF NOT EXISTS silver.sat_rent_data (
    raw_id        bigint      PRIMARY KEY REFERENCES bronze.raw_record(raw_id) ON DELETE CASCADE,
    hub_key       text        REFERENCES silver.hub_rent_observation(hub_key),
    load_date     timestamptz NOT NULL,
    hash_diff     text        NOT NULL,
    load_status   text        NOT NULL CHECK (load_status IN ('accepted', 'rejected', 'duplicate')),
    payload       jsonb       NOT NULL,
    record_source text        NOT NULL DEFAULT 'NSW_RENT_BONDS'
);
CREATE INDEX IF NOT EXISTS sat_rent_data_hub_load_idx ON silver.sat_rent_data (hub_key, load_date);

INSERT INTO silver.sat_rent_data (raw_id, hub_key, load_date, hash_diff, load_status, payload)
SELECT rr.raw_id, h.hub_key, b._loaded_at, md5(rr.payload::text), rr.load_status, rr.payload
  FROM bronze.raw_record rr
  JOIN bronze.ingest_file f ON f.source_file = rr.source_file
  JOIN bronze.rent_data b ON b._raw_record_id = rr.raw_id
  LEFT JOIN silver.hub_rent_observation h ON h.hub_key = md5(b.rent_id::text)
 WHERE f.source_name = 'rent_data'
ON CONFLICT (raw_id) DO NOTHING;

-- 6. traffic_segment_hourly
-- Hub: one row per segment_id+observation_date+hour_of_day, same pattern as bus_stop.

CREATE TABLE IF NOT EXISTS silver.hub_traffic_segment (
    hub_key          text        PRIMARY KEY,
    segment_id       text        NOT NULL,
    observation_date date        NOT NULL,
    hour_of_day      smallint    NOT NULL,
    load_date        timestamptz NOT NULL DEFAULT now(),
    record_source    text        NOT NULL DEFAULT 'TFNSW_TRAFFIC_VOLUME_COUNTS'
);

INSERT INTO silver.hub_traffic_segment (hub_key, segment_id, observation_date, hour_of_day)
SELECT DISTINCT md5(segment_id || '|' || observation_date::text || '|' || hour_of_day::text),
       segment_id, observation_date, hour_of_day
  FROM bronze.traffic_segment_hourly
 WHERE segment_id IS NOT NULL AND observation_date IS NOT NULL AND hour_of_day IS NOT NULL
ON CONFLICT (hub_key) DO NOTHING;

CREATE TABLE IF NOT EXISTS silver.sat_traffic_volume (
    raw_id        bigint      PRIMARY KEY REFERENCES bronze.raw_record(raw_id) ON DELETE CASCADE,
    hub_key       text        REFERENCES silver.hub_traffic_segment(hub_key),
    load_date     timestamptz NOT NULL,
    hash_diff     text        NOT NULL,
    load_status   text        NOT NULL CHECK (load_status IN ('accepted', 'rejected', 'duplicate')),
    payload       jsonb       NOT NULL,
    record_source text        NOT NULL DEFAULT 'TFNSW_TRAFFIC_VOLUME_COUNTS'
);
CREATE INDEX IF NOT EXISTS sat_traffic_volume_hub_load_idx ON silver.sat_traffic_volume (hub_key, load_date);

INSERT INTO silver.sat_traffic_volume (raw_id, hub_key, load_date, hash_diff, load_status, payload)
SELECT rr.raw_id, h.hub_key, b._loaded_at, md5(rr.payload::text), rr.load_status, rr.payload
  FROM bronze.raw_record rr
  JOIN bronze.ingest_file f ON f.source_file = rr.source_file
  JOIN bronze.traffic_segment_hourly b ON b._raw_record_id = rr.raw_id
  LEFT JOIN silver.hub_traffic_segment h
         ON h.hub_key = md5(b.segment_id || '|' || b.observation_date::text || '|' || b.hour_of_day::text)
 WHERE f.source_name = 'traffic_volume'
ON CONFLICT (raw_id) DO NOTHING;
