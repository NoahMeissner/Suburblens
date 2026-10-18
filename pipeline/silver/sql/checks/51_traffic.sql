-- Checks for the traffic volume tables.
-- Raw-row accounting for traffic_volume is already covered by the
-- sat_traffic_volume check in checks/02_lineage_vault.sql.

SELECT 'silver.traffic_segment_hourly'::text, 'count_non_negative'::text, 'validity'::text, 'error'::text,
       (SELECT count(*) FROM silver.traffic_segment_hourly WHERE is_usable AND avg_vehicle_count < 0),
       (SELECT count(*) FROM silver.traffic_segment_hourly), NULL::numeric, NULL::jsonb
UNION ALL
SELECT 'silver.traffic_segment_hourly', 'max_ge_avg', 'consistency', 'error',
       (SELECT count(*) FROM silver.traffic_segment_hourly
         WHERE is_usable AND max_vehicle_count IS NOT NULL AND avg_vehicle_count IS NOT NULL
           AND max_vehicle_count < avg_vehicle_count),
       (SELECT count(*) FROM silver.traffic_segment_hourly), NULL, NULL
UNION ALL
-- A missing hour must never be averaged as zero traffic, so 52 averages over
-- observed hours only. This reports which segment-days are incomplete.
SELECT 'silver.traffic_segment_hourly', 'hour_completeness', 'completeness', 'warn',
       (SELECT count(*) FROM silver.traffic_segment_hourly WHERE flag_partial_day),
       (SELECT count(*) FROM silver.traffic_segment_hourly), 0.05, NULL
UNION ALL
SELECT 'silver.traffic_segment_hourly', 'low_quality_excluded', 'consistency', 'error',
       (SELECT count(*) FROM silver.traffic_segment_hourly
         WHERE is_usable AND (coalesce(quality_flag,'')<>'reported' OR coalesce(min_station_quality,0)<5 OR coalesce(observation_count,0)<1)),
       (SELECT count(*) FROM silver.traffic_segment_hourly), NULL,
       (SELECT jsonb_object_agg(coalesce(quality_flag, 'NULL'), n)
          FROM (SELECT quality_flag, count(*) n FROM silver.traffic_segment_hourly
                 GROUP BY 1) q)
UNION ALL
-- Rush hours must carry more traffic than the night. If they do not, the hour
-- axis is shifted - a timezone bug, or hour_of_day read as UTC.
SELECT 'silver.traffic_segment_daypart', 'diurnal_shape', 'accuracy', 'warn',
       (SELECT CASE WHEN (SELECT avg(avg_vehicles_per_hour) FROM silver.traffic_segment_daypart
                           WHERE daypart = 'rush')
                         > (SELECT avg(avg_vehicles_per_hour) FROM silver.traffic_segment_daypart
                             WHERE daypart = 'night')
                    THEN 0 ELSE 1 END)::bigint,
       1::bigint, NULL,
       (SELECT jsonb_object_agg(daypart, round(avg_vph, 1))
          FROM (SELECT daypart, avg(avg_vehicles_per_hour) avg_vph
                  FROM silver.traffic_segment_daypart
                 WHERE daypart_kind = 'summary' GROUP BY 1) q)
UNION ALL
SELECT 'silver.traffic_segment_daypart', 'low_sample', 'accuracy', 'warn',
       (SELECT count(*) FROM silver.traffic_segment_daypart WHERE flag_low_sample),
       (SELECT count(*) FROM silver.traffic_segment_daypart), 0.10, NULL
UNION ALL
SELECT 'silver.traffic_segment_hourly','synthetic_source','accuracy','warn',
 (SELECT count(*) FROM bronze.ingest_file WHERE source_name='traffic_volume' AND is_synthetic),
 1::bigint,NULL,jsonb_build_object('note','synthetic fixture; no production claim')
UNION ALL
-- Without segment geometry the 500 m stop join cannot run at all. Reported as
-- a coverage fact, so it is visible rather than silently absent.
SELECT 'silver.traffic_segment', 'segment_geometry_present', 'completeness', 'warn',
       (SELECT count(DISTINCT h.segment_id) FROM silver.traffic_segment_hourly h
         WHERE NOT EXISTS (SELECT 1 FROM silver.traffic_segment t
                            WHERE t.segment_id = h.segment_id AND t.geom_m IS NOT NULL)),
       (SELECT count(DISTINCT segment_id) FROM silver.traffic_segment_hourly), 0.0,
       jsonb_build_object('note',
           'missing segment reference prevents spatial integration');
