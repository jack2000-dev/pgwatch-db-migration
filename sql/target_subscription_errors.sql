-- PostgreSQL 18 form. PG17 uses the same query without conflict counters;
-- see config/metrics/target_subscription_errors.yaml for both versions.
SELECT
    sub.subname AS tag_subscription,
    stats.apply_error_count::bigint,
    stats.sync_error_count::bigint,
    COALESCE(extract(epoch FROM stats.stats_reset), 0)::double precision AS stats_reset_epoch_s,
    stats.confl_insert_exists::bigint,
    stats.confl_update_origin_differs::bigint,
    stats.confl_update_exists::bigint,
    stats.confl_update_missing::bigint,
    stats.confl_delete_origin_differs::bigint,
    stats.confl_delete_missing::bigint,
    stats.confl_multiple_unique_conflicts::bigint
FROM pg_catalog.pg_stat_subscription_stats AS stats
JOIN pg_catalog.pg_subscription AS sub ON sub.oid = stats.subid
WHERE sub.subdbid = (SELECT oid FROM pg_catalog.pg_database WHERE datname = current_database());

