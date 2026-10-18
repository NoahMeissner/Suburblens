-- Checks for the spine: silver.bus_stop, silver.bus_edge, silver.hex_300m.
-- Raw-row accounting for bus_stops is already covered by the sat_bus_stop
-- check in checks/02_lineage_vault.sql.

SELECT 'silver.bus_stop'::text, 'geom_not_null'::text, 'completeness'::text, 'error'::text,
       (SELECT count(*) FROM silver.bus_stop WHERE geom IS NULL OR geom_m IS NULL),
       (SELECT count(*) FROM silver.bus_stop), NULL::numeric, NULL::jsonb
UNION ALL
SELECT 'silver.bus_stop', 'geom_valid', 'validity', 'error',
       (SELECT count(*) FROM silver.bus_stop
         WHERE NOT ST_IsValid(geom) OR ST_IsEmpty(geom)
            OR ST_SRID(geom) <> 4326 OR ST_SRID(geom_m) <> 7856),
       (SELECT count(*) FROM silver.bus_stop), NULL, NULL
UNION ALL
SELECT 'silver.bus_stop', 'hex_assigned', 'completeness', 'error',
       (SELECT count(*) FROM silver.bus_stop WHERE hex_id IS NULL),
       (SELECT count(*) FROM silver.bus_stop), NULL, NULL
UNION ALL
-- 69 stops genuinely have no edge; that is flagged, not an error. This warns
-- only if the share moves, which would mean the edges feed changed shape.
SELECT 'silver.bus_stop', 'stops_without_service', 'consistency', 'warn',
       (SELECT count(*) FROM silver.bus_stop WHERE flag_no_service),
       (SELECT count(*) FROM silver.bus_stop), 0.01, NULL
UNION ALL
-- Opposite-direction stop pairs legitimately sit metres apart; identical points
-- do not. Warn only.
SELECT 'silver.bus_stop', 'duplicate_location_5m', 'uniqueness', 'warn',
       (SELECT count(*) FROM silver.bus_stop a
         WHERE EXISTS (SELECT 1 FROM silver.bus_stop b
                        WHERE b.stop_id <> a.stop_id
                          AND ST_DWithin(a.geom_m, b.geom_m, 5))),
       (SELECT count(*) FROM silver.bus_stop), 0.05, NULL
UNION ALL
SELECT 'silver.bus_stop', 'routes_served_known', 'consistency', 'warn',
       (SELECT count(*) FROM silver.bus_stop s
         WHERE EXISTS (SELECT 1 FROM unnest(s.routes_served) AS r
                        WHERE NOT EXISTS (SELECT 1 FROM bronze.bus_routes br
                                           WHERE br.route_short_name = r))),
       (SELECT count(*) FROM silver.bus_stop), 0.02, NULL
UNION ALL
-- The hexagons must actually be the 300 m cells they claim to be: flat-to-flat
-- 300 m means an area of 77,942 m2. A silent CRS or size change shows up here
-- before it quietly distorts every density measure.
SELECT 'silver.hex_300m', 'cell_size_is_300m', 'accuracy', 'error',
       (SELECT count(*) FROM silver.hex_300m WHERE abs(area_m2 - 77942.21) > 1),
       (SELECT count(*) FROM silver.hex_300m), NULL,
       (SELECT jsonb_build_object('min_area_m2', min(area_m2), 'max_area_m2', max(area_m2),
                                  'expected_m2', 77942.21) FROM silver.hex_300m)
UNION ALL
-- k-ring 1 is the cell plus 6 neighbours. Fewer than 7 is only legitimate at
-- the edge of the grid, so this is capped as a fraction rather than forbidden.
SELECT 'silver.hex_300m_neighbour', 'kring_is_seven', 'consistency', 'warn',
       (SELECT count(*) FROM (SELECT hex_id FROM silver.hex_300m_neighbour
                               GROUP BY hex_id HAVING count(*) <> 7) q),
       (SELECT count(*) FROM silver.hex_300m), 0.05, NULL
UNION ALL
SELECT 'silver.bus_edge', 'endpoints_exist', 'consistency', 'error',
       (SELECT count(*) FROM silver.bus_edge e
         WHERE NOT EXISTS (SELECT 1 FROM silver.bus_stop s WHERE s.stop_id = e.from_stop_id)
            OR NOT EXISTS (SELECT 1 FROM silver.bus_stop s WHERE s.stop_id = e.to_stop_id)),
       (SELECT count(*) FROM silver.bus_edge), NULL, NULL
UNION ALL
-- lineage bridge must account for every single raw feature, or measures were
-- either dropped or double-counted.
SELECT 'silver.bus_edge', 'dedup_reconciles', 'completeness', 'error',
       abs((SELECT coalesce(sum(n_source_rows), 0) FROM silver.bus_edge)
           - (SELECT count(*) FROM silver.bus_edge_source))::bigint,
       (SELECT count(*) FROM bronze.bus_graph_edges)::bigint,
       NULL,
       jsonb_build_object(
           'logical_edges', (SELECT count(*) FROM silver.bus_edge),
           'source_rows_claimed', (SELECT coalesce(sum(n_source_rows), 0) FROM silver.bus_edge),
           'lineage_rows', (SELECT count(*) FROM silver.bus_edge_source),
           'bronze_rows', (SELECT count(*) FROM bronze.bus_graph_edges))
UNION ALL
SELECT 'silver.bus_edge', 'route_id_exists', 'consistency', 'warn',
       (SELECT count(*) FROM silver.bus_edge e
         WHERE NOT EXISTS (SELECT 1 FROM bronze.bus_routes r WHERE r.route_id = e.route_id)),
       (SELECT count(*) FROM silver.bus_edge), NULL, NULL;
