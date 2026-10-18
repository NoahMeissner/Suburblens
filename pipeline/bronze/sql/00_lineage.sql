-- Bronze lineage: one row per loaded file, one row per raw record in it.
--
-- Every bronze.<table> row carries a _raw_record_id pointing back here, so
-- Silver can account for every raw row exactly once via the Hub/Satellite
-- tables in 02_lineage_vault.sql, and show the raw payload behind a rejected
-- or superseded row (silver.dq_reject) without re-reading the source file.

CREATE SCHEMA IF NOT EXISTS bronze;

-- This just documents, which files were uploaded into the Database
CREATE TABLE IF NOT EXISTS bronze.ingest_file (
    -- The Source File path is primary key
    source_file  text         PRIMARY KEY,
    source_name  text         NOT NULL,
    row_count    integer      NOT NULL,
    is_synthetic boolean      NOT NULL DEFAULT false,
    loaded_at    timestamptz  NOT NULL DEFAULT now()
);

-- This makes it possible to just check when data was loaded
CREATE INDEX IF NOT EXISTS ingest_file_source_name_idx
    ON bronze.ingest_file (source_name);

-- Here we just save all the Rows as JSON Object
CREATE TABLE IF NOT EXISTS bronze.raw_record (
    raw_id      bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_file text         NOT NULL,
    source_row  bigint       NOT NULL,
    payload     jsonb        NOT NULL,
    load_status text         NOT NULL DEFAULT 'accepted',
    reason      text,
    loaded_at   timestamptz  NOT NULL DEFAULT now(),
    -- Rule that only those three could be saved into the column
    CONSTRAINT raw_record_load_status_check
        CHECK (load_status IN ('accepted', 'rejected', 'duplicate'))
);
-- Created a combined Index from Path and Row Number
-- Performance thing when we request the ids then we get those in millisecondes, because of this index
CREATE INDEX IF NOT EXISTS raw_record_source_idx
    ON bronze.raw_record (source_file, source_row);
