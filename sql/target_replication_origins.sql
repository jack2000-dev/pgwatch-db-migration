-- PostgreSQL 17/18 subscriber. "Active" is an intentionally conservative
-- inference for subscription-managed origins named pg_<subscription_oid>.
SELECT
    origin.external_id AS tag_origin,
    COALESCE(sub.subname, '') AS tag_subscription,
    origin.local_id::bigint AS local_id,
    COALESCE(origin.remote_lsn::text, '') AS remote_lsn,
    COALESCE(origin.local_lsn::text, '') AS local_lsn,
    (sub.oid IS NOT NULL AND EXISTS (
        SELECT 1 FROM pg_catalog.pg_stat_subscription AS st
        WHERE st.subid = sub.oid AND st.pid IS NOT NULL
    ))::int AS active,
    count(*) OVER ()::bigint AS origin_count,
    count(*) FILTER (
      WHERE sub.oid IS NOT NULL AND EXISTS (
        SELECT 1 FROM pg_catalog.pg_stat_subscription AS st2
        WHERE st2.subid = sub.oid AND st2.pid IS NOT NULL
      )
    ) OVER ()::bigint AS active_origin_count
FROM pg_catalog.pg_replication_origin_status AS origin
JOIN pg_catalog.pg_subscription AS sub
  ON origin.external_id = 'pg_' || sub.oid::text
 AND sub.subdbid = (SELECT oid FROM pg_catalog.pg_database WHERE datname = current_database());
