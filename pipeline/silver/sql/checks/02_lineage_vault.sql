-- Checks for the Hub/Satellite lineage layer (02_lineage_vault.sql).
--
-- Two concerns: (1) every Satellite must be a complete history, never a
-- silent collapse - it must have exactly as many rows as bronze.raw_record
-- has for that source; (2) for the two sources with real multi-version
-- source data (property_sales, bus_routes), that history must actually be
-- visible as more than one Satellite row per business key, not just
-- reconcile on paper.

SELECT 'silver.sat_bus_stop'::text, 'raw_accounting'::text, 'completeness'::text, 'error'::text,
       abs((SELECT count(*) FROM silver.sat_bus_stop)
           - (SELECT count(*) FROM bronze.raw_record rr JOIN bronze.ingest_file f
               ON f.source_file = rr.source_file WHERE f.source_name = 'bus_stops'))::bigint,
       (SELECT count(*) FROM bronze.raw_record rr JOIN bronze.ingest_file f
          ON f.source_file = rr.source_file WHERE f.source_name = 'bus_stops')::bigint,
       NULL::numeric, NULL::jsonb
UNION ALL
SELECT 'silver.sat_bus_route', 'raw_accounting', 'completeness', 'error',
       abs((SELECT count(*) FROM silver.sat_bus_route)
           - (SELECT count(*) FROM bronze.raw_record rr JOIN bronze.ingest_file f
               ON f.source_file = rr.source_file WHERE f.source_name = 'bus_routes'))::bigint,
       (SELECT count(*) FROM bronze.raw_record rr JOIN bronze.ingest_file f
          ON f.source_file = rr.source_file WHERE f.source_name = 'bus_routes')::bigint,
       NULL, NULL
UNION ALL
SELECT 'silver.sat_school', 'raw_accounting', 'completeness', 'error',
       abs((SELECT count(*) FROM silver.sat_school)
           - (SELECT count(*) FROM bronze.raw_record rr JOIN bronze.ingest_file f
               ON f.source_file = rr.source_file WHERE f.source_name = 'school_location'))::bigint,
       (SELECT count(*) FROM bronze.raw_record rr JOIN bronze.ingest_file f
          ON f.source_file = rr.source_file WHERE f.source_name = 'school_location')::bigint,
       NULL, NULL
UNION ALL
SELECT 'silver.sat_da_application', 'raw_accounting', 'completeness', 'error',
       abs((SELECT count(*) FROM silver.sat_da_application)
           - (SELECT count(*) FROM bronze.raw_record rr JOIN bronze.ingest_file f
               ON f.source_file = rr.source_file WHERE f.source_name = 'da_applications'))::bigint,
       (SELECT count(*) FROM bronze.raw_record rr JOIN bronze.ingest_file f
          ON f.source_file = rr.source_file WHERE f.source_name = 'da_applications')::bigint,
       NULL, NULL
UNION ALL
SELECT 'silver.sat_property_sales', 'raw_accounting', 'completeness', 'error',
       abs((SELECT count(*) FROM silver.sat_property_sales)
           - (SELECT count(*) FROM bronze.raw_record rr JOIN bronze.ingest_file f
               ON f.source_file = rr.source_file WHERE f.source_name = 'property_sales'))::bigint,
       (SELECT count(*) FROM bronze.raw_record rr JOIN bronze.ingest_file f
          ON f.source_file = rr.source_file WHERE f.source_name = 'property_sales')::bigint,
       NULL, NULL
UNION ALL
SELECT 'silver.sat_rent_data', 'raw_accounting', 'completeness', 'error',
       abs((SELECT count(*) FROM silver.sat_rent_data)
           - (SELECT count(*) FROM bronze.raw_record rr JOIN bronze.ingest_file f
               ON f.source_file = rr.source_file WHERE f.source_name = 'rent_data'))::bigint,
       (SELECT count(*) FROM bronze.raw_record rr JOIN bronze.ingest_file f
          ON f.source_file = rr.source_file WHERE f.source_name = 'rent_data')::bigint,
       NULL, NULL
UNION ALL
SELECT 'silver.sat_traffic_volume', 'raw_accounting', 'completeness', 'error',
       abs((SELECT count(*) FROM silver.sat_traffic_volume)
           - (SELECT count(*) FROM bronze.raw_record rr JOIN bronze.ingest_file f
               ON f.source_file = rr.source_file WHERE f.source_name = 'traffic_volume'))::bigint,
       (SELECT count(*) FROM bronze.raw_record rr JOIN bronze.ingest_file f
          ON f.source_file = rr.source_file WHERE f.source_name = 'traffic_volume')::bigint,
       NULL, NULL
UNION ALL
-- The actual payoff over the old collapse-based lineage: these business keys
-- now carry more than one Satellite row instead of only the winner.
SELECT 'silver.sat_property_sales', 'multi_version_keys_present', 'accuracy', 'warn',
       (SELECT CASE WHEN count(*) > 0 THEN 0 ELSE 1 END
          FROM (SELECT hub_key FROM silver.sat_property_sales
                 WHERE hub_key IS NOT NULL GROUP BY hub_key HAVING count(*) > 1) v)::bigint,
       1::bigint, NULL,
       (SELECT jsonb_build_object('n_versioned_keys', count(*), 'max_versions', max(n))
          FROM (SELECT hub_key, count(*) n FROM silver.sat_property_sales
                 WHERE hub_key IS NOT NULL GROUP BY hub_key HAVING count(*) > 1) v)
UNION ALL
SELECT 'silver.sat_bus_route', 'multi_version_keys_present', 'accuracy', 'warn',
       (SELECT CASE WHEN count(*) > 0 THEN 0 ELSE 1 END
          FROM (SELECT hub_key FROM silver.sat_bus_route
                 WHERE hub_key IS NOT NULL GROUP BY hub_key HAVING count(*) > 1) v)::bigint,
       1::bigint, NULL,
       (SELECT jsonb_build_object('n_versioned_keys', count(*), 'max_versions', max(n))
          FROM (SELECT hub_key, count(*) n FROM silver.sat_bus_route
                 WHERE hub_key IS NOT NULL GROUP BY hub_key HAVING count(*) > 1) v);
