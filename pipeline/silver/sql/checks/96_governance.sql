-- Quality gates for auditability and real-vs-synthetic segregation.
SELECT 'bronze.ingest_file'::text,'synthetic_only_in_demo_database'::text,'accuracy'::text,'error'::text,
 count(*) FILTER (WHERE is_synthetic AND right(current_database(),5) <> '_demo'),
 count(*),NULL::numeric,NULL::jsonb
FROM bronze.ingest_file;
