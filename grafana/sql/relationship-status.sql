WITH inventory AS (
  SELECT profile_name, enabled, provider, instance, role, migration_pair,
         last_seen_in_registry
  FROM monitoring_profile_inventory
  WHERE retired_at IS NULL AND role IN ('publisher', 'subscriber')
), expected AS (
  SELECT p.profile_name AS publisher, t.profile_name AS subscriber,
         COALESCE(p.migration_pair, t.migration_pair) AS migration_pair,
         p.provider AS source_provider, p.instance AS source_instance,
         t.provider AS target_provider, t.instance AS target_instance,
         p.enabled AS source_enabled, t.enabled AS target_enabled,
         p.last_seen_in_registry AS source_registered,
         t.last_seen_in_registry AS target_registered
  FROM (SELECT * FROM inventory WHERE role = 'publisher') p
  FULL JOIN (SELECT * FROM inventory WHERE role = 'subscriber') t
    ON p.migration_pair = t.migration_pair AND p.migration_pair <> ''
), slot_window AS (
  SELECT time, dbname AS publisher, tag_data->>'migration_pair' AS migration_pair,
         tag_data->>'slot_name' AS slot, tag_data->>'database' AS source_database,
         COALESCE((data->>'lag_bytes')::bigint, 0) AS lag_bytes,
         COALESCE((data->>'active')::int, 0) AS active,
         COALESCE((data->>'publisher_streaming_count')::int, 0) AS streaming
  FROM source_replication_slot WHERE time > now() - interval '5 minutes'
), slots AS (
  SELECT publisher, migration_pair, slot,
         (array_agg(source_database ORDER BY time DESC))[1] AS source_database,
         (array_agg(lag_bytes ORDER BY time DESC))[1] AS lag_bytes,
         min(time) AS first_seen, max(time) AS last_seen,
         bool_and(active = 1 AND streaming > 0) AS healthy,
         bool_and(lag_bytes = 0) AS lag_zero
  FROM slot_window GROUP BY publisher, migration_pair, slot
), subscription_window AS (
  SELECT time, dbname AS subscriber, tag_data->>'migration_pair' AS migration_pair,
         tag_data->>'subscription' AS subscription, tag_data->>'slot_name' AS slot,
         COALESCE((data->>'enabled')::int, 0) AS enabled,
         COALESCE((data->>'subscription_status')::int, -1) AS subscription_status,
         COALESCE((data->>'apply_worker_count')::int, 0) AS apply_workers
  FROM target_subscription WHERE time > now() - interval '5 minutes'
), subscriptions AS (
  SELECT subscriber, migration_pair, subscription, slot,
         min(time) AS first_seen, max(time) AS last_seen,
         bool_and(enabled = 1 AND subscription_status = 1 AND apply_workers > 0) AS healthy
  FROM subscription_window GROUP BY subscriber, migration_pair, subscription, slot
), error_points AS (
  SELECT time, dbname AS subscriber, tag_data->>'subscription' AS subscription,
         COALESCE((data->>'apply_error_count')::bigint, 0) AS apply_errors,
         COALESCE((data->>'sync_error_count')::bigint, 0) AS sync_errors,
         COALESCE((data->>'stats_reset_epoch_s')::double precision, 0) AS reset_epoch
  FROM target_subscription_errors WHERE time > now() - interval '5 minutes'
), error_changes AS (
  SELECT *, greatest(apply_errors - lag(apply_errors) OVER error_order, 0)
              + greatest(sync_errors - lag(sync_errors) OVER error_order, 0) AS new_errors
  FROM error_points WINDOW error_order AS (PARTITION BY subscriber, subscription ORDER BY time)
), errors AS (
  SELECT subscriber, subscription, min(time) AS first_seen, max(time) AS last_seen,
         COALESCE(sum(new_errors), 0)::bigint AS new_errors,
         min(reset_epoch) = max(reset_epoch) AS reset_stable
  FROM error_changes GROUP BY subscriber, subscription
), table_window AS (
  SELECT time, dbname AS subscriber, tag_data->>'subscription' AS subscription,
         COALESCE((data->>'total_tables')::bigint, 0) AS total_tables,
         COALESCE((data->>'non_ready_tables')::bigint, 0) AS non_ready_tables
  FROM target_table_sync WHERE time > now() - interval '5 minutes'
), tables AS (
  SELECT subscriber, subscription,
         (array_agg(total_tables ORDER BY time DESC))[1] AS total_tables,
         (array_agg(non_ready_tables ORDER BY time DESC))[1] AS non_ready_tables,
         min(time) AS first_seen, max(time) AS last_seen,
         bool_and(total_tables > 0 AND non_ready_tables = 0) AS healthy
  FROM table_window GROUP BY subscriber, subscription
), validations AS (
  SELECT DISTINCT ON (migration_pair) migration_pair, status, validated_at
  FROM cutover_validation ORDER BY migration_pair, validated_at DESC
), databases AS (
  SELECT DISTINCT ON (dbname) dbname AS profile,
         COALESCE(NULLIF(tag_data->>'database', ''), dbname) AS database
  FROM general_database WHERE time > now() - interval '5 minutes'
  ORDER BY dbname, time DESC
), relationships AS (
  SELECT x.*, sub.subscription, sub.slot, sub.first_seen AS target_first_seen,
         sub.last_seen AS target_last_seen, sub.healthy AS target_healthy,
         s.source_database, s.lag_bytes, s.first_seen AS source_first_seen,
         s.last_seen AS source_last_seen, s.healthy AS source_healthy, s.lag_zero
  FROM expected x
  LEFT JOIN subscriptions sub ON sub.subscriber = x.subscriber AND sub.migration_pair = x.migration_pair
  LEFT JOIN slots s ON s.publisher = x.publisher AND s.migration_pair = x.migration_pair AND s.slot = sub.slot
), status_inputs AS (
  SELECT r.*, COALESCE(r.source_database, sd.database, r.publisher, '—') AS source_database_name,
         COALESCE(td.database, r.subscriber, '—') AS target_database_name,
         e.new_errors, e.reset_stable, e.first_seen AS error_first_seen,
         e.last_seen AS error_last_seen, t.total_tables, t.non_ready_tables,
         t.healthy AS tables_healthy, t.first_seen AS tables_first_seen,
         t.last_seen AS tables_last_seen, v.status AS data_validation, v.validated_at,
         (r.publisher IS NULL OR r.subscriber IS NULL OR r.subscription IS NULL
          OR (SELECT count(*) FROM inventory i WHERE i.role = 'publisher'
              AND i.migration_pair = r.migration_pair) <> 1
          OR (SELECT count(*) FROM subscriptions candidate
              WHERE candidate.migration_pair = r.migration_pair
                AND candidate.slot = r.slot) > 1
          OR r.source_provider IS NULL OR r.source_instance IS NULL
          OR r.target_provider IS NULL OR r.target_instance IS NULL
          OR r.source_registered < now() - interval '120 seconds'
          OR r.target_registered < now() - interval '120 seconds'
          OR r.source_last_seen < now() - interval '90 seconds'
          OR r.target_last_seen < now() - interval '90 seconds'
          OR e.last_seen < now() - interval '90 seconds'
          OR t.last_seen < now() - interval '90 seconds'
          OR r.source_last_seen IS NULL OR r.target_last_seen IS NULL
          OR e.last_seen IS NULL OR t.last_seen IS NULL) AS missing_or_stale,
         (r.source_first_seen > now() - interval '4 minutes'
          OR r.target_first_seen > now() - interval '4 minutes'
          OR e.first_seen > now() - interval '4 minutes'
          OR t.first_seen > now() - interval '4 minutes') AS window_too_new
  FROM relationships r
  LEFT JOIN errors e ON e.subscriber = r.subscriber AND e.subscription = r.subscription
  LEFT JOIN tables t ON t.subscriber = r.subscriber AND t.subscription = r.subscription
  LEFT JOIN validations v ON v.migration_pair = r.migration_pair
  LEFT JOIN databases sd ON sd.profile = r.publisher
  LEFT JOIN databases td ON td.profile = r.subscriber
), status AS (
  SELECT *,
    CASE WHEN missing_or_stale OR NOT COALESCE(source_enabled, false)
                   OR NOT COALESCE(target_enabled, false) THEN 'UNKNOWN'
         WHEN NOT source_healthy OR NOT target_healthy OR NOT tables_healthy
                   OR new_errors > 5 THEN 'CRITICAL'
         WHEN NOT lag_zero OR new_errors > 0 OR NOT reset_stable THEN 'WARNING'
         ELSE 'HEALTHY' END AS health_status,
    CASE WHEN missing_or_stale OR window_too_new
                   OR NOT COALESCE(source_enabled, false)
                   OR NOT COALESCE(target_enabled, false) THEN 'UNKNOWN'
         WHEN NOT source_healthy OR NOT target_healthy OR NOT tables_healthy
                   OR new_errors > 5 THEN 'NOT READY'
         WHEN NOT lag_zero OR new_errors > 0 OR NOT reset_stable THEN 'WARNING'
         WHEN data_validation IS NULL THEN 'DATA CHECK REQUIRED'
         WHEN data_validation <> 'PASS' THEN 'NOT READY'
         ELSE 'READY' END AS cutover_status
  FROM status_inputs
)
SELECT COALESCE(source_provider, '—') AS source_provider,
       COALESCE(source_instance, publisher, '—') AS source_instance,
       COALESCE(target_provider, '—') AS target_provider,
       COALESCE(target_instance, subscriber, '—') AS target_instance,
       source_database_name AS source_database, target_database_name AS target_database,
       publisher, subscriber, migration_pair, slot, subscription,
       lag_bytes, new_errors AS errors,
       CASE WHEN tables_last_seen IS NULL OR tables_last_seen < now() - interval '90 seconds'
                 THEN 'UNKNOWN'
            WHEN total_tables > 0 AND non_ready_tables = 0 THEN 'YES'
            ELSE 'NO' END AS tables_ready,
       health_status, cutover_status, data_validation, validated_at
FROM status
UNION ALL
SELECT COALESCE(provider, '—'), COALESCE(instance, profile_name), '—', '—',
       profile_name, '—', profile_name, NULL, migration_pair, NULL, NULL,
       NULL, NULL, 'UNKNOWN', 'UNKNOWN', 'UNKNOWN', NULL, NULL
FROM monitoring_profile_inventory
WHERE retired_at IS NULL AND (role IS NULL OR role NOT IN ('publisher', 'subscriber'))
