-- End-to-end completeness and missing-data handling.
SELECT 'bronze.ingest_file'::text,'at_least_three_sources'::text,'completeness'::text,'error'::text,
 CASE WHEN count(*)>=3 THEN 0 ELSE 1 END::bigint,1::bigint,NULL,NULL
 FROM bronze.ingest_file WHERE row_count>0
UNION ALL
SELECT 'bronze.ingest_file','required_sources_nonempty','completeness','error',
 (SELECT count(*) FROM (VALUES('bus_stops'),('bus_routes'),('bus_graph_edges'),('school_location'),
 ('da_applications'),('property_sales'),('rent_data'),('traffic_volume')) v(name)
 WHERE NOT EXISTS(SELECT 1 FROM bronze.ingest_file f WHERE f.source_name=v.name AND f.row_count>0)),
 8::bigint,NULL,NULL
UNION ALL
SELECT 'silver.school','unlocated_excluded','validity','error',
 count(*) FILTER(WHERE is_usable AND geom_m IS NULL),count(*),NULL,NULL FROM silver.school
UNION ALL
SELECT 'silver.rent_observation','missing_or_invalid_excluded','validity','error',
 count(*) FILTER(WHERE is_usable AND (flag_missing_rent OR flag_invalid_value)),count(*),NULL,NULL FROM silver.rent_observation
UNION ALL
SELECT 'silver.rent_observation','missing_rent','completeness','warn',
 count(*) FILTER(WHERE flag_missing_rent),count(*),NULL,NULL FROM silver.rent_observation
UNION ALL
SELECT 'silver.bus_stop_rent','LGA_key_matches','consistency','error',
 (SELECT count(*) FROM silver.bus_stop_rent b JOIN silver.rent_observation r USING(rent_id)
 JOIN silver.bus_stop_lga l USING(stop_id) WHERE r.lga_key<>l.lga_code),
 (SELECT count(*) FROM silver.bus_stop_rent),NULL,NULL
UNION ALL
SELECT 'silver.bus_edge_travel_time','flagged_times_not_usable','validity','error',
 count(*) FILTER(WHERE is_usable AND (flag_zero_timepoint OR flag_layover OR flag_low_sample OR flag_implausible_speed)),
 count(*),NULL,NULL FROM silver.bus_edge_travel_time
UNION ALL
SELECT 'silver.bus_stop_profile','required_profile_nonempty','completeness','error',
 CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint,1::bigint,NULL,NULL FROM silver.bus_stop_profile;
