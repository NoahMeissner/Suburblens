CREATE SCHEMA IF NOT EXISTS bronze;
-- Create Data Table
CREATE TABLE IF NOT EXISTS bronze.rent_data (
    rent_id              integer      NOT NULL,
    lga_name             text,
    period_start         date,
    dwelling_type        text,
    median_weekly_rent   numeric(10,2),
    new_bonds_count      integer,
    reliability_flag     text,
    -- Lineage: where the row comes from, when it was loaded
    _source_file         text         NOT NULL,
    _loaded_at           timestamptz  NOT NULL DEFAULT now(),
    _raw_record_id       bigint       REFERENCES bronze.raw_record(raw_id),

    CONSTRAINT rent_data_pkey PRIMARY KEY (rent_id)
);
-- Connect with Linaege
ALTER TABLE bronze.rent_data
    ADD COLUMN IF NOT EXISTS _raw_record_id bigint REFERENCES bronze.raw_record(raw_id);
CREATE INDEX IF NOT EXISTS rent_data_raw_record_idx
    ON bronze.rent_data (_raw_record_id);
