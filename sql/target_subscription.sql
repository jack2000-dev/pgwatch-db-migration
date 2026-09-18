-- PostgreSQL 17/18 subscriber. Does not expose pg_subscription.subconninfo.
SELECT
    sub.subname AS tag_subscription,
    COALESCE(st.worker_type, 'none') AS tag_worker_type,
    COALESCE(ns.nspname || '.' || c.relname, '') AS tag_relation,
    COALESCE(sub.subslotname, '') AS tag_slot_name,
    pg_catalog.array_to_json(sub.subpublications)::text AS tag_publications,
    sub.subenabled::int AS enabled,
    CASE
      WHEN NOT sub.subenabled THEN 0
      WHEN count(*) FILTER (WHERE st.worker_type = 'apply') OVER (PARTITION BY sub.oid) > 0 THEN 1
      ELSE -1
    END::bigint AS subscription_status,
    COALESCE(st.pid, 0)::bigint AS pid,
    COALESCE(st.leader_pid, 0)::bigint AS leader_pid,
    COALESCE(st.relid, 0)::bigint AS relid,
    COALESCE(st.received_lsn::text, '') AS received_lsn,
    COALESCE(st.latest_end_lsn::text, '') AS latest_end_lsn,
    COALESCE(extract(epoch FROM st.last_msg_send_time), 0)::double precision AS last_msg_send_epoch_s,
    COALESCE(extract(epoch FROM st.last_msg_receipt_time), 0)::double precision AS last_msg_receipt_epoch_s,
    COALESCE(extract(epoch FROM st.latest_end_time), 0)::double precision AS latest_end_epoch_s,
    COALESCE(extract(epoch FROM clock_timestamp() - st.last_msg_receipt_time), -1)::double precision AS message_age_seconds,
    count(*) FILTER (WHERE st.worker_type = 'apply') OVER (PARTITION BY sub.oid)::bigint AS apply_worker_count,
    count(*) FILTER (WHERE st.worker_type = 'table synchronization') OVER (PARTITION BY sub.oid)::bigint AS table_sync_worker_count
FROM pg_catalog.pg_subscription AS sub
LEFT JOIN pg_catalog.pg_stat_subscription AS st ON st.subid = sub.oid
LEFT JOIN pg_catalog.pg_class AS c ON c.oid = st.relid
LEFT JOIN pg_catalog.pg_namespace AS ns ON ns.oid = c.relnamespace
WHERE sub.subdbid = (SELECT oid FROM pg_catalog.pg_database WHERE datname = current_database());

