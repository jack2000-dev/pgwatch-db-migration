#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${ENV_FILE:-$project_dir/.env}"
failures=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
skip() { printf 'SKIP: %s\n' "$1"; }
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
for var in METRICS_DB_NAME METRICS_DB_USER GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD PGWATCH_WEB_USER PGWATCH_WEB_PASSWORD; do
  [[ -n "${!var:-}" ]] || { echo "ERROR: $var is required in $env_file" >&2; exit 1; }
done
[[ -n "${DB_PGPASSFILE_HOST:-}" ]] || { echo "ERROR: DB_PGPASSFILE_HOST is required in $env_file" >&2; exit 1; }
[[ -f "$DB_PGPASSFILE_HOST" ]] || { echo "ERROR: PostgreSQL passfile is missing: $DB_PGPASSFILE_HOST" >&2; exit 1; }
[[ -r "$DB_PGPASSFILE_HOST" ]] || { echo "ERROR: PostgreSQL passfile is not readable: $DB_PGPASSFILE_HOST" >&2; exit 1; }
chmod 0600 "$DB_PGPASSFILE_HOST"
source_sslmode="${SOURCE_DB_SSLMODE:-verify-full}"
target_sslmode="${TARGET_DB_SSLMODE:-verify-full}"

running="$(docker compose --env-file "$env_file" ps --services --filter status=running 2>/dev/null || true)"
for service in metrics-db pgwatch grafana; do
  if grep -qx "$service" <<<"$running"; then pass "Docker service $service is running"; else fail "Docker service $service is not running"; fi
done

config_table="$(docker compose --env-file "$env_file" exec -T metrics-db psql -X -qAt -U "$METRICS_DB_USER" -d "$METRICS_DB_NAME" -v ON_ERROR_STOP=1 -c "SELECT to_regclass('pgwatch.source') IS NOT NULL;" 2>/dev/null || true)"
if [[ "$config_table" == t ]]; then
  pass "PostgreSQL-backed pgwatch source registry exists"
else
  fail "PostgreSQL-backed pgwatch source registry is missing"
fi

pgwatch_host="${PGWATCH_WEB_BIND_ADDRESS:-127.0.0.1}"
[[ "$pgwatch_host" != "0.0.0.0" ]] || pgwatch_host=127.0.0.1
pgwatch_url="http://$pgwatch_host:${PGWATCH_WEB_PORT:-8080}"
login_body="$(jq -nc --arg user "$PGWATCH_WEB_USER" --arg password "$PGWATCH_WEB_PASSWORD" '{user: $user, password: $password}')"
source_count=0
if pgwatch_token="$(curl -fsS --max-time 10 -H 'Content-Type: application/json' -d "$login_body" "$pgwatch_url/login" 2>/dev/null)" && [[ -n "$pgwatch_token" ]]; then
  pass "pgwatch Web UI authentication succeeds"
  if sources_json="$(curl -fsS --max-time 10 -H "Token: $pgwatch_token" "$pgwatch_url/source" 2>/dev/null)" && source_count="$(jq -er 'if type == "array" then length else error("not an array") end' <<<"$sources_json" 2>/dev/null)"; then
    pass "pgwatch source API reports $source_count profile(s)"
  else
    fail "pgwatch source API is unavailable"
    source_count=0
  fi
else
  fail "pgwatch Web UI authentication failed"
fi

psql_readonly() {
  local host="$1" port="$2" db="$3" user="$4" sslmode="$5" ca="$6"
  shift 6
  local -a connection_env=("PGPASSFILE=$DB_PGPASSFILE_HOST" "PGSSLMODE=$sslmode" "PGAPPNAME=pgwatch-validation" "PGOPTIONS=-c default_transaction_read_only=on -c statement_timeout=5s -c lock_timeout=1s")
  [[ "$sslmode" != verify-ca && "$sslmode" != verify-full ]] || connection_env+=("PGSSLROOTCERT=$ca")
  env -u PGPASSWORD -u PGSSLROOTCERT "${connection_env[@]}" psql -X --no-psqlrc -v ON_ERROR_STOP=1 -qAt -h "$host" -p "$port" -d "$db" -U "$user" "$@"
}

profile_configured=true
for var in SOURCE_DB_HOST SOURCE_DB_PORT SOURCE_DB_NAME SOURCE_DB_USER TARGET_DB_HOST TARGET_DB_PORT TARGET_DB_NAME TARGET_DB_USER; do
  if [[ -z "${!var:-}" || "${!var}" == *replace-with* || "${!var}" == *.example.com ]]; then
    profile_configured=false
  fi
done

if "$profile_configured"; then
if source_version="$(psql_readonly "$SOURCE_DB_HOST" "$SOURCE_DB_PORT" "$SOURCE_DB_NAME" "$SOURCE_DB_USER" "$source_sslmode" "${SOURCE_DB_SSLROOTCERT_HOST:-}" -c "SHOW server_version" 2>/dev/null)" && [[ -n "$source_version" ]]; then
  pass "pgwatch_monitor connects to source (PostgreSQL $source_version)"
else
  fail "source connection/version query failed"
fi
if target_version="$(psql_readonly "$TARGET_DB_HOST" "$TARGET_DB_PORT" "$TARGET_DB_NAME" "$TARGET_DB_USER" "$target_sslmode" "${TARGET_DB_SSLROOTCERT_HOST:-}" -c "SHOW server_version" 2>/dev/null)" && [[ -n "$target_version" ]]; then
  pass "pgwatch_monitor connects to target (PostgreSQL $target_version)"
else
  fail "target connection/version query failed"
fi
else
  skip "direct SQL checks; optional SOURCE_DB_* and TARGET_DB_* validation pair is not configured"
fi

if grep -Ein '\b(drop|alter|truncate|vacuum|create|grant|revoke|reset|set)\b' sql/*.sql >/dev/null; then
  fail "standalone SQL contains a statement outside the read-only allowlist"
else
  pass "standalone SQL passes the monitoring-only safety scan"
fi

if "$profile_configured"; then
if psql_readonly "$SOURCE_DB_HOST" "$SOURCE_DB_PORT" "$SOURCE_DB_NAME" "$SOURCE_DB_USER" "$source_sslmode" "${SOURCE_DB_SSLROOTCERT_HOST:-}" -f sql/source_replication_slot.sql >/dev/null 2>&1; then
  pass "source replication-slot SQL executes"
else
  fail "source replication-slot SQL failed"
fi
for sql_file in target_subscription.sql target_subscription_errors.sql target_table_sync.sql target_replication_origins.sql; do
  if psql_readonly "$TARGET_DB_HOST" "$TARGET_DB_PORT" "$TARGET_DB_NAME" "$TARGET_DB_USER" "$target_sslmode" "${TARGET_DB_SSLROOTCERT_HOST:-}" -f "sql/$sql_file" >/dev/null 2>&1; then
    pass "$sql_file executes on target"
  else
    fail "$sql_file failed on target"
  fi
done
fi

grafana_url="http://${GRAFANA_BIND_ADDRESS:-127.0.0.1}:${GRAFANA_PORT:-3000}"
grafana_auth="$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD"
if curl -fsS --max-time 10 -u "$grafana_auth" "$grafana_url/api/datasources/uid/pgwatch-metrics" | jq -e '.uid == "pgwatch-metrics"' >/dev/null 2>&1; then
  pass "Grafana datasource exists"
else
  fail "Grafana datasource is missing or unavailable"
fi
if curl -fsS --max-time 10 -u "$grafana_auth" "$grafana_url/api/dashboards/uid/logical-replication-migration" | jq -e '.dashboard.title == "PostgreSQL Logical Replication Migration"' >/dev/null 2>&1; then
  pass "Grafana detail dashboard is provisioned"
else
  fail "Grafana detail dashboard is missing or unavailable"
fi
if curl -fsS --max-time 10 -u "$grafana_auth" "$grafana_url/api/dashboards/uid/logical-replication-overview" | jq -e '.dashboard.title == "PostgreSQL Migration Fleet Overview" and .dashboard.panels[0].type == "table"' >/dev/null 2>&1; then
  pass "Grafana fleet overview is provisioned"
else
  fail "Grafana fleet overview is missing or unavailable"
fi
if alerts_json="$(curl -fsS --max-time 10 -u "$grafana_auth" "$grafana_url/api/v1/provisioning/alert-rules" 2>/dev/null)" && jq -e 'length >= 9 and all(.[]; .isPaused == true)' <<<"$alerts_json" >/dev/null; then
  pass "nine alert rules are provisioned and paused"
else
  fail "alert rules are missing, unavailable, or not all paused"
fi

if (( source_count > 0 )); then
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

overview_sql="$(jq -er '.panels[] | select(.id == 1) | .targets[0].rawSql' grafana/dashboards/logical-replication-overview.json 2>/dev/null || true)"
if [[ -z "$overview_sql" ]]; then
  fail "fleet overview SQL is missing from the dashboard"
else
  overview_count="$(docker compose --env-file "$env_file" exec -T metrics-db psql -X -qAt -U "$METRICS_DB_USER" -d "$METRICS_DB_NAME" -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM ($overview_sql) AS overview;" 2>/dev/null || true)"
  if [[ "$overview_count" =~ ^[0-9]+$ ]] && (( overview_count > 0 )); then
    pass "fleet overview SQL returns at least one migration"
  else
    fail "fleet overview SQL failed or returned no migrations"
  fi
fi
else
  skip "fresh metric and fleet-row checks; add publisher/subscriber profiles in the pgwatch Web UI"
fi

if (( failures > 0 )); then
  echo "Validation completed with $failures failure(s)." >&2
  exit 1
fi
echo "Validation successful."
