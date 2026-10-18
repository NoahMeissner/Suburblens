-- Checks for the address report's dimensional mart.

SELECT 'gold.fact_address'::text, 'row_count_matches_address_point'::text,
       'completeness'::text, 'error'::text,
       abs((SELECT count(*) FROM gold.fact_address)
           - (SELECT count(*) FROM gold.address_point))::bigint,
       (SELECT count(*) FROM gold.address_point)::bigint, NULL::numeric, NULL::jsonb
UNION ALL
SELECT 'gold.fact_address', 'locality_fk_resolves', 'consistency', 'error',
       (SELECT count(*) FROM gold.fact_address fa
         WHERE fa.locality_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM gold.dim_locality dl WHERE dl.locality_id = fa.locality_id)),
       (SELECT count(*) FROM gold.fact_address), NULL, NULL
UNION ALL
SELECT 'gold.fact_address', 'street_fk_resolves', 'consistency', 'error',
       (SELECT count(*) FROM gold.fact_address fa
         WHERE fa.street_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM gold.dim_street ds WHERE ds.street_id = fa.street_id)),
       (SELECT count(*) FROM gold.fact_address), NULL, NULL
UNION ALL
-- street_id must be present for the 'street' tier and absent for 'address'
-- (the DA address is unparsed - see gold/sql/30_address_point.sql).
SELECT 'gold.fact_address', 'street_id_matches_precision', 'consistency', 'error',
       (SELECT count(*) FROM gold.fact_address
         WHERE (precision = 'street' AND street_id IS NULL)
            OR (precision = 'address' AND street_id IS NOT NULL)),
       (SELECT count(*) FROM gold.fact_address), NULL, NULL
UNION ALL
SELECT 'gold.fact_address', 'accuracy_bucket_consistent', 'accuracy', 'error',
       (SELECT count(*) FROM gold.fact_address
         WHERE accuracy_bucket <> (CASE WHEN accuracy_m = 0 THEN 'exact'
                                         WHEN accuracy_m <= 100 THEN '<=100m'
                                         WHEN accuracy_m <= 300 THEN '100-300m'
                                         ELSE '>300m' END)),
       (SELECT count(*) FROM gold.fact_address), NULL, NULL
UNION ALL
SELECT 'gold.dim_locality', 'locality_id_unique_per_row', 'validity', 'error',
       (SELECT count(*) - count(DISTINCT locality_id) FROM gold.dim_locality),
       (SELECT count(*) FROM gold.dim_locality), NULL, NULL;
