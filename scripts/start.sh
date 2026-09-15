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

required_vars=(
  SOURCE_PGWATCH_NAME TARGET_PGWATCH_NAME
  SOURCE_DB_HOST SOURCE_DB_PORT SOURCE_DB_NAME SOURCE_DB_USER SOURCE_DB_PASSWORD SOURCE_DB_SSLROOTCERT_HOST
  TARGET_DB_HOST TARGET_DB_PORT TARGET_DB_NAME TARGET_DB_USER TARGET_DB_PASSWORD TARGET_DB_SSLROOTCERT_HOST
  METRICS_DB_NAME METRICS_DB_USER METRICS_DB_PASSWORD GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD
)
for var in "${required_vars[@]}"; do
  [[ -n "${!var:-}" ]] || { echo "ERROR: $var is required in $env_file" >&2; exit 1; }
  [[ "${!var}" != *replace-with* ]] || { echo "ERROR: replace the placeholder value for $var" >&2; exit 1; }
done
[[ -r "$SOURCE_DB_SSLROOTCERT_HOST" ]] || { echo "ERROR: source CA is not readable: $SOURCE_DB_SSLROOTCERT_HOST" >&2; exit 1; }
[[ -r "$TARGET_DB_SSLROOTCERT_HOST" ]] || { echo "ERROR: target CA is not readable: $TARGET_DB_SSLROOTCERT_HOST" >&2; exit 1; }

uri_encode() { jq -nr --arg value "$1" '$value|@uri'; }
uri_host() {
  if [[ "$1" == *:* ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi
}
build_db_uri() {
  local user="$1" password="$2" host="$3" port="$4" database="$5" ca_path="$6" app_name="$7"
  local options='-cdefault_transaction_read_only=on -cstatement_timeout=5s -clock_timeout=1s'
  printf 'postgresql://%s:%s@%s:%s/%s?sslmode=verify-full&sslrootcert=%s&application_name=%s&options=%s' "$(uri_encode "$user")" "$(uri_encode "$password")" "$(uri_host "$host")" "$port" "$(uri_encode "$database")" "$(uri_encode "$ca_path")" "$(uri_encode "$app_name")" "$(uri_encode "$options")"
}

export SOURCE_DB_CONN_STR
SOURCE_DB_CONN_STR="$(build_db_uri "$SOURCE_DB_USER" "$SOURCE_DB_PASSWORD" "$SOURCE_DB_HOST" "$SOURCE_DB_PORT" "$SOURCE_DB_NAME" /run/pgwatch-certs/source-ca.crt pgwatch-logical-publisher)"
export TARGET_DB_CONN_STR
TARGET_DB_CONN_STR="$(build_db_uri "$TARGET_DB_USER" "$TARGET_DB_PASSWORD" "$TARGET_DB_HOST" "$TARGET_DB_PORT" "$TARGET_DB_NAME" /run/pgwatch-certs/target-ca.crt pgwatch-logical-subscriber)"
export METRICS_DB_CONN_STR
METRICS_DB_CONN_STR="postgresql://$(uri_encode "$METRICS_DB_USER"):$(uri_encode "$METRICS_DB_PASSWORD")@metrics-db:5432/$(uri_encode "$METRICS_DB_NAME")?sslmode=disable"

cd "$project_dir"
docker compose --env-file "$env_file" config --quiet
docker compose --env-file "$env_file" up -d --wait --wait-timeout 120

echo "Stack started."
echo "Grafana: http://127.0.0.1:${GRAFANA_PORT:-3000}"
echo "Run: ./scripts/validate.sh"
