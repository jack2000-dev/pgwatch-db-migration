#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${ENV_FILE:-$project_dir/.env}"

command -v docker >/dev/null || { echo "ERROR: docker is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq is required to safely URL-encode credentials" >&2; exit 1; }
[[ -f "$env_file" ]] || { echo "ERROR: copy .env.example to .env and edit it" >&2; exit 1; }
chmod 0600 "$env_file"

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a
CONFIG_DB_NAME="${CONFIG_DB_NAME:-pgwatch_config}"

required_vars=(
  DB_PGPASSFILE_HOST
  METRICS_DB_NAME METRICS_DB_USER METRICS_DB_PASSWORD
  GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD
  PGWATCH_WEB_USER PGWATCH_WEB_PASSWORD
)
for var in "${required_vars[@]}"; do
  [[ -n "${!var:-}" ]] || { echo "ERROR: $var is required in $env_file" >&2; exit 1; }
  [[ "${!var}" != *replace-with* ]] || { echo "ERROR: replace the placeholder value for $var" >&2; exit 1; }
done
[[ "$CONFIG_DB_NAME" != "$METRICS_DB_NAME" ]] || { echo "ERROR: CONFIG_DB_NAME and METRICS_DB_NAME must differ" >&2; exit 1; }
[[ -f "$DB_PGPASSFILE_HOST" ]] || { echo "ERROR: PostgreSQL passfile is missing: $DB_PGPASSFILE_HOST" >&2; exit 1; }
[[ -r "$DB_PGPASSFILE_HOST" ]] || { echo "ERROR: PostgreSQL passfile is not readable: $DB_PGPASSFILE_HOST" >&2; exit 1; }
chmod 0600 "$DB_PGPASSFILE_HOST"

certs_dir="${DB_CERTS_DIR_HOST:-$project_dir/secrets/certs}"
[[ "$certs_dir" == /* ]] || certs_dir="$project_dir/$certs_dir"
[[ -d "$certs_dir" ]] || { echo "ERROR: certificate directory is missing: $certs_dir" >&2; exit 1; }
export DB_CERTS_DIR_HOST="$certs_dir"

uri_encode() { jq -nr --arg value "$1" '$value|@uri'; }
export METRICS_DB_CONN_STR
METRICS_DB_CONN_STR="postgresql://$(uri_encode "$METRICS_DB_USER"):$(uri_encode "$METRICS_DB_PASSWORD")@metrics-db:5432/$(uri_encode "$METRICS_DB_NAME")?sslmode=disable"
export CONFIG_DB_CONN_STR
CONFIG_DB_CONN_STR="postgresql://$(uri_encode "$METRICS_DB_USER"):$(uri_encode "$METRICS_DB_PASSWORD")@metrics-db:5432/$(uri_encode "$CONFIG_DB_NAME")?sslmode=disable"

cd "$project_dir"
docker compose --env-file "$env_file" config --quiet
docker compose --env-file "$env_file" up -d --wait --wait-timeout 120 metrics-db

if ! docker compose --env-file "$env_file" exec -T metrics-db \
  psql -X -qAt -U "$METRICS_DB_USER" -d postgres -c 'SELECT datname FROM pg_database' \
  | grep -Fxq "$CONFIG_DB_NAME"; then
  docker compose --env-file "$env_file" exec -T metrics-db \
    createdb -U "$METRICS_DB_USER" -O "$METRICS_DB_USER" "$CONFIG_DB_NAME"
fi

config_table="$(docker compose --env-file "$env_file" exec -T metrics-db \
  psql -X -qAt -U "$METRICS_DB_USER" -d "$CONFIG_DB_NAME" \
  -c "SELECT to_regclass('pgwatch.source');")"
if [[ "$config_table" != pgwatch.source ]]; then
  docker compose --env-file "$env_file" run --rm --no-deps \
    --entrypoint env pgwatch -u PW_METRICS -u PW_SINK /pgwatch/pgwatch config init
fi

docker compose --env-file "$env_file" exec -T metrics-db \
  psql -X -qAt -v ON_ERROR_STOP=1 -U "$METRICS_DB_USER" -d "$METRICS_DB_NAME" \
  -c "CREATE TABLE IF NOT EXISTS cutover_validation (migration_pair text NOT NULL, validated_at timestamptz NOT NULL DEFAULT now(), status text NOT NULL CHECK (status IN ('PASS', 'FAIL', 'ERROR')), source_database text NOT NULL, target_database text NOT NULL, publication text NOT NULL, subscription text NOT NULL, tables bigint NOT NULL DEFAULT 0, source_rows bigint NOT NULL DEFAULT 0, target_rows bigint NOT NULL DEFAULT 0, differences bigint NOT NULL DEFAULT 0); CREATE INDEX IF NOT EXISTS cutover_validation_pair_time_idx ON cutover_validation (migration_pair, validated_at DESC);"

docker compose --env-file "$env_file" up -d --wait --wait-timeout 120

echo "Stack started."
echo "Grafana: http://${GRAFANA_BIND_ADDRESS:-127.0.0.1}:${GRAFANA_PORT:-3000}"
echo "pgwatch Web UI: http://${PGWATCH_WEB_BIND_ADDRESS:-127.0.0.1}:${PGWATCH_WEB_PORT:-8080}"
echo "Run: ./scripts/validate.sh"
