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
  DB_PGPASSFILE_HOST
  SOURCE_DB_HOST SOURCE_DB_PORT SOURCE_DB_NAME SOURCE_DB_USER
  TARGET_DB_HOST TARGET_DB_PORT TARGET_DB_NAME TARGET_DB_USER
  METRICS_DB_NAME METRICS_DB_USER METRICS_DB_PASSWORD GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD
)
for var in "${required_vars[@]}"; do
  [[ -n "${!var:-}" ]] || { echo "ERROR: $var is required in $env_file" >&2; exit 1; }
  [[ "${!var}" != *replace-with* ]] || { echo "ERROR: replace the placeholder value for $var" >&2; exit 1; }
done
[[ -f "$DB_PGPASSFILE_HOST" ]] || { echo "ERROR: PostgreSQL passfile is missing: $DB_PGPASSFILE_HOST" >&2; exit 1; }
[[ -r "$DB_PGPASSFILE_HOST" ]] || { echo "ERROR: PostgreSQL passfile is not readable: $DB_PGPASSFILE_HOST" >&2; exit 1; }
chmod 0600 "$DB_PGPASSFILE_HOST"
source_sslmode="${SOURCE_DB_SSLMODE:-verify-full}"
target_sslmode="${TARGET_DB_SSLMODE:-verify-full}"
validate_ssl() {
  local label="$1" mode="$2" ca_path="$3"
  case "$mode" in
    disable|allow|prefer|require|verify-ca|verify-full) ;;
    *) echo "ERROR: $label SSL mode must be disable, allow, prefer, require, verify-ca, or verify-full" >&2; exit 1 ;;
  esac
  case "$mode" in
    verify-ca|verify-full)
      [[ -n "$ca_path" ]] || { echo "ERROR: $label CA path is required for sslmode=$mode" >&2; exit 1; }
      [[ -r "$ca_path" ]] || { echo "ERROR: $label CA is not readable: $ca_path" >&2; exit 1; }
      ;;
    require)
      echo "WARNING: $label sslmode=require encrypts traffic but does not verify the server hostname." >&2
      ;;
    disable|allow|prefer)
      echo "WARNING: $label sslmode=$mode can use an unencrypted connection." >&2
      ;;
  esac
}
validate_ssl source "$source_sslmode" "${SOURCE_DB_SSLROOTCERT_HOST:-}"
validate_ssl target "$target_sslmode" "${TARGET_DB_SSLROOTCERT_HOST:-}"

uri_encode() { jq -nr --arg value "$1" '$value|@uri'; }
uri_host() {
  if [[ "$1" == *:* ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi
}
build_db_uri() {
  local user="$1" host="$2" port="$3" database="$4" sslmode="$5" ca_path="$6" app_name="$7"
  local options='-cdefault_transaction_read_only=on -cstatement_timeout=5s -clock_timeout=1s'
  printf 'postgresql://%s@%s:%s/%s?sslmode=%s&passfile=%s' "$(uri_encode "$user")" "$(uri_host "$host")" "$port" "$(uri_encode "$database")" "$(uri_encode "$sslmode")" "$(uri_encode /run/pgwatch-secrets/pgpass)"
  [[ -z "$ca_path" ]] || printf '&sslrootcert=%s' "$(uri_encode "$ca_path")"
  printf '&application_name=%s&options=%s' "$(uri_encode "$app_name")" "$(uri_encode "$options")"
}

source_ca_path=""
target_ca_path=""
export SOURCE_DB_SSLROOTCERT_MOUNT=/dev/null
export TARGET_DB_SSLROOTCERT_MOUNT=/dev/null
if [[ "$source_sslmode" == verify-ca || "$source_sslmode" == verify-full ]]; then
  source_ca_path=/run/pgwatch-certs/source-ca.crt
  SOURCE_DB_SSLROOTCERT_MOUNT="$SOURCE_DB_SSLROOTCERT_HOST"
fi
if [[ "$target_sslmode" == verify-ca || "$target_sslmode" == verify-full ]]; then
  target_ca_path=/run/pgwatch-certs/target-ca.crt
  TARGET_DB_SSLROOTCERT_MOUNT="$TARGET_DB_SSLROOTCERT_HOST"
fi

export SOURCE_DB_CONN_STR
SOURCE_DB_CONN_STR="$(build_db_uri "$SOURCE_DB_USER" "$SOURCE_DB_HOST" "$SOURCE_DB_PORT" "$SOURCE_DB_NAME" "$source_sslmode" "$source_ca_path" pgwatch-logical-publisher)"
export TARGET_DB_CONN_STR
TARGET_DB_CONN_STR="$(build_db_uri "$TARGET_DB_USER" "$TARGET_DB_HOST" "$TARGET_DB_PORT" "$TARGET_DB_NAME" "$target_sslmode" "$target_ca_path" pgwatch-logical-subscriber)"
export METRICS_DB_CONN_STR
METRICS_DB_CONN_STR="postgresql://$(uri_encode "$METRICS_DB_USER"):$(uri_encode "$METRICS_DB_PASSWORD")@metrics-db:5432/$(uri_encode "$METRICS_DB_NAME")?sslmode=disable"

cd "$project_dir"
docker compose --env-file "$env_file" config --quiet
docker compose --env-file "$env_file" up -d --wait --wait-timeout 120

echo "Stack started."
echo "Grafana: http://${GRAFANA_BIND_ADDRESS:-127.0.0.1}:${GRAFANA_PORT:-3000}"
echo "Run: ./scripts/validate.sh"
