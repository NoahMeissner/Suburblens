CREATE SCHEMA IF NOT EXISTS bronze;

-- This just creates the table for the Traffic Volume
CREATE TABLE IF NOT EXISTS bronze.traffic_segment_hourly (
    segment_id           text         NOT NULL,          -- e.g. SEG001, not numeric
    observation_date     date         NOT NULL,
    hour_of_day          smallint     NOT NULL,
    avg_vehicle_count    numeric(12,4),                  -- fractional, it is an average
    max_vehicle_count    integer,
    observation_count    integer,
    station_count        integer,
    min_station_quality  smallint,
    quality_flag         text,                           -- 'reported' | 'caution'
    record_source        text,
    transformed_at       timestamptz,
    -- Lineage: where the row comes from, when it was loaded
    _source_file         text         NOT NULL,
    _loaded_at           timestamptz  NOT NULL DEFAULT now(),
    _raw_record_id       bigint       REFERENCES bronze.raw_record(raw_id),

    CONSTRAINT traffic_segment_hourly_pkey
        PRIMARY KEY (segment_id, observation_date, hour_of_day),
    CONSTRAINT traffic_segment_hourly_hour_of_day_check
        CHECK (hour_of_day BETWEEN 0 AND 23)
);

-- Brings Foreign Key from Linaege to make data source transparent
ALTER TABLE bronze.traffic_segment_hourly
    ADD COLUMN IF NOT EXISTS _raw_record_id bigint REFERENCES bronze.raw_record(raw_id);
-- Index the foreign key: reloading a file deletes its raw_record rows, and
-- Postgres checks every referencing table per deleted row. Without this
-- index each check is a full scan.
CREATE INDEX IF NOT EXISTS traffic_segment_hourly_raw_record_idx
    ON bronze.traffic_segment_hourly (_raw_record_id);
