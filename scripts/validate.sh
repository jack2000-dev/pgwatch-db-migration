#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${ENV_FILE:-$project_dir/.env}"
failures=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
need() { command -v "$1" >/dev/null || { echo "ERROR: $1 is required" >&2; exit 1; }; }

need docker
need psql
need curl
need jq
[[ -f "$env_file" ]] || { echo "ERROR: missing $env_file" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a
cd "$project_dir"

running="$(docker compose --env-file "$env_file" ps --services --filter status=running 2>/dev/null || true)"
for service in metrics-db pgwatch grafana; do
  if grep -qx "$service" <<<"$running"; then pass "Docker service $service is running"; else fail "Docker service $service is not running"; fi
done

psql_readonly() {
  local host="$1" port="$2" db="$3" user="$4" password="$5" ca="$6"
  shift 6
  PGPASSWORD="$password" PGSSLMODE=verify-full PGSSLROOTCERT="$ca" PGAPPNAME=pgwatch-validation PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=5s -c lock_timeout=1s' psql -X --no-psqlrc -v ON_ERROR_STOP=1 -qAt -h "$host" -p "$port" -d "$db" -U "$user" "$@"
}

if source_version="$(psql_readonly "$SOURCE_DB_HOST" "$SOURCE_DB_PORT" "$SOURCE_DB_NAME" "$SOURCE_DB_USER" "$SOURCE_DB_PASSWORD" "$SOURCE_DB_SSLROOTCERT_HOST" -c "SELECT current_setting('server_version_num')::int / 10000" 2>/dev/null)" && [[ "$source_version" == 17 ]]; then
  pass "pgwatch_monitor connects to PostgreSQL 17 source"
else
  fail "source connection/version check failed (expected PostgreSQL 17)"
fi
if target_version="$(psql_readonly "$TARGET_DB_HOST" "$TARGET_DB_PORT" "$TARGET_DB_NAME" "$TARGET_DB_USER" "$TARGET_DB_PASSWORD" "$TARGET_DB_SSLROOTCERT_HOST" -c "SELECT current_setting('server_version_num')::int / 10000" 2>/dev/null)" && [[ "$target_version" == 18 ]]; then
  pass "pgwatch_monitor connects to PostgreSQL 18 target"
else
  fail "target connection/version check failed (expected PostgreSQL 18)"
fi

if grep -Ein '\b(drop|alter|truncate|vacuum|create|grant|revoke|reset|set)\b' sql/*.sql >/dev/null; then
  fail "standalone SQL contains a statement outside the read-only allowlist"
else
  pass "standalone SQL passes the monitoring-only safety scan"
fi

if psql_readonly "$SOURCE_DB_HOST" "$SOURCE_DB_PORT" "$SOURCE_DB_NAME" "$SOURCE_DB_USER" "$SOURCE_DB_PASSWORD" "$SOURCE_DB_SSLROOTCERT_HOST" -f sql/source_replication_slot.sql >/dev/null 2>&1; then
  pass "source replication-slot SQL executes"
else
  fail "source replication-slot SQL failed"
fi
for sql_file in target_subscription.sql target_subscription_errors.sql target_table_sync.sql target_replication_origins.sql; do
  if psql_readonly "$TARGET_DB_HOST" "$TARGET_DB_PORT" "$TARGET_DB_NAME" "$TARGET_DB_USER" "$TARGET_DB_PASSWORD" "$TARGET_DB_SSLROOTCERT_HOST" -f "sql/$sql_file" >/dev/null 2>&1; then
    pass "$sql_file executes on target"
  else
    fail "$sql_file failed on target"
  fi
done

grafana_url="http://127.0.0.1:${GRAFANA_PORT:-3000}"
grafana_auth="$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD"
if curl -fsS --max-time 10 -u "$grafana_auth" "$grafana_url/api/datasources/uid/pgwatch-metrics" | jq -e '.uid == "pgwatch-metrics"' >/dev/null 2>&1; then
  pass "Grafana datasource exists"
else
  fail "Grafana datasource is missing or unavailable"
fi
if curl -fsS --max-time 10 -u "$grafana_auth" "$grafana_url/api/dashboards/uid/logical-replication-migration" | jq -e '.dashboard.title == "PostgreSQL Logical Replication Migration"' >/dev/null 2>&1; then
  pass "Grafana dashboard is provisioned"
else
  fail "Grafana dashboard is missing or unavailable"
fi
if alerts_json="$(curl -fsS --max-time 10 -u "$grafana_auth" "$grafana_url/api/v1/provisioning/alert-rules" 2>/dev/null)" && jq -e 'length >= 9 and all(.[]; .isPaused == true)' <<<"$alerts_json" >/dev/null; then
  pass "nine alert rules are provisioned and paused"
else
  fail "alert rules are missing, unavailable, or not all paused"
fi

remaining_metrics=(source_replication_slot target_subscription target_subscription_errors target_table_sync target_replication_origins instance_up general_database)
for attempt in {1..12}; do
  next_remaining=()
  for table in "${remaining_metrics[@]}"; do
    count="$(docker compose --env-file "$env_file" exec -T metrics-db psql -X -qAt -U "$METRICS_DB_USER" -d "$METRICS_DB_NAME" -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM \"$table\" WHERE time > now() - interval '3 minutes';" 2>/dev/null || true)"
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
      pass "fresh rows are arriving in $table"
    else
      next_remaining+=("$table")
    fi
  done
  remaining_metrics=("${next_remaining[@]}")
  (( ${#remaining_metrics[@]} == 0 )) && break
  (( attempt < 12 )) && sleep 10
done
for table in "${remaining_metrics[@]}"; do
  fail "no fresh rows arrived in metric table $table"
done

if (( failures > 0 )); then
  echo "Validation completed with $failures failure(s)." >&2
  exit 1
fi
echo "Validation successful."
