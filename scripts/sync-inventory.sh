#!/bin/sh
set -eu

export PGPASSWORD="$METRICS_DB_PASSWORD"

sync_once() {
  snapshot="$(psql -X -qAt -v ON_ERROR_STOP=1 -h metrics-db -U "$METRICS_DB_USER" -d "$CONFIG_DB_NAME" -c "
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'profile_name', name,
      'enabled', is_enabled,
      'provider', custom_tags->>'provider',
      'instance', custom_tags->>'instance',
      'role', custom_tags->>'migration_role',
      'migration_pair', custom_tags->>'migration_pair'
    )), '[]'::jsonb)
    FROM pgwatch.source
    WHERE dbtype = 'postgres'
      AND (preset_config IN ('logical_replication_publisher', 'logical_replication_subscriber')
        OR custom_tags->>'migration_role' IS NOT NULL
        OR custom_tags->>'migration_pair' IS NOT NULL);")" || return 1
  [ -n "$snapshot" ] || return 1

  # ponytail: argv snapshot fits the expected tens of profiles; stream it if the registry grows past shell argument limits.
  psql -X -q -v ON_ERROR_STOP=1 -v snapshot="$snapshot" -h metrics-db -U "$METRICS_DB_USER" -d "$METRICS_DB_NAME" <<'SQL'
BEGIN;
INSERT INTO monitoring_profile_inventory
  (profile_name, enabled, provider, instance, role, migration_pair, last_seen_in_registry, retired_at)
SELECT profile_name, enabled, provider, instance, role, migration_pair, now(), NULL
FROM jsonb_to_recordset(:'snapshot'::jsonb) AS item
  (profile_name text, enabled boolean, provider text, instance text, role text, migration_pair text)
ON CONFLICT (profile_name) DO UPDATE SET
  enabled = EXCLUDED.enabled,
  provider = EXCLUDED.provider,
  instance = EXCLUDED.instance,
  role = EXCLUDED.role,
  migration_pair = EXCLUDED.migration_pair,
  last_seen_in_registry = EXCLUDED.last_seen_in_registry,
  retired_at = NULL;
UPDATE monitoring_profile_inventory SET retired_at = now()
WHERE retired_at IS NULL AND last_seen_in_registry < now();
COMMIT;
SQL
}

if [ "${1:-}" = '--once' ]; then
  sync_once
else
  while :; do
    sync_once || echo 'Inventory sync failed; retrying in 60 seconds' >&2
    sleep 60
  done
fi
