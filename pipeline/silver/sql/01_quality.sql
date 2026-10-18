-- Data-quality framework: checks are data, not scattered asserts.

-- Documentation of every Data Quality Pipeline
CREATE TABLE IF NOT EXISTS silver.dq_run (
    run_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    n_checks    integer,
    n_failed    integer,
    passed      boolean
);

-- Specific Test Results
-- So we now in DQ RUN when what happend and if failed or succeeeded and here more details
CREATE TABLE IF NOT EXISTS silver.dq_result (
    run_id      bigint      NOT NULL REFERENCES silver.dq_run ON DELETE CASCADE,
    table_name  text        NOT NULL,       -- 'silver.da_application'
    check_name  text        NOT NULL,       -- 'coord_matches_council'
    dimension   text        NOT NULL,       -- see the CHECK below
    severity    text        NOT NULL,       -- 'error' aborts the run, 'warn' reports
    failed_rows bigint      NOT NULL,
    total_rows  bigint      NOT NULL,
    threshold   numeric,                    -- max tolerated failed fraction, NULL = 0
    passed      boolean     NOT NULL,
    detail      jsonb,                      -- free-form context, e.g. sample keys
    checked_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT dq_result_pkey PRIMARY KEY (run_id, table_name, check_name),
    CONSTRAINT dq_result_dimension_check CHECK (dimension IN (
        'completeness', 'uniqueness', 'validity',
        'consistency', 'accuracy', 'timeliness')),
    CONSTRAINT dq_result_severity_check CHECK (severity IN ('error', 'warn'))
);

-- Make it easier to check for fails
CREATE INDEX IF NOT EXISTS dq_result_failed_idx
    ON silver.dq_result (run_id, passed) WHERE NOT passed;

-- When Data is Failed we can check that here
CREATE TABLE IF NOT EXISTS silver.dq_reject (
    run_id       bigint NOT NULL REFERENCES silver.dq_run ON DELETE CASCADE,
    source_table text   NOT NULL,           -- 'bronze.da_applications'
    source_key   text   NOT NULL,           -- the business key as text
    check_name   text   NOT NULL,
    reason       text,
    payload      jsonb                       -- the offending row, for triage
);
-- index to faster search
CREATE INDEX IF NOT EXISTS dq_reject_run_idx
    ON silver.dq_reject (run_id, source_table);
