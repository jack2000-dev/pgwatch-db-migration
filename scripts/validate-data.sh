#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${ENV_FILE:-$project_dir/.env}"

command -v python3 >/dev/null || { echo "ERROR: python3 is required" >&2; exit 2; }
command -v psql >/dev/null || { echo "ERROR: psql is required" >&2; exit 2; }
command -v stdbuf >/dev/null || { echo "ERROR: stdbuf is required" >&2; exit 2; }
[[ -f "$env_file" ]] || { echo "ERROR: missing $env_file" >&2; exit 2; }
chmod 0600 "$env_file"

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a
export SOURCE_DB_SSLMODE="${SOURCE_DB_SSLMODE:-verify-full}"
export TARGET_DB_SSLMODE="${TARGET_DB_SSLMODE:-verify-full}"

required_vars=(
  DB_PGPASSFILE_HOST
  SOURCE_DB_HOST SOURCE_DB_PORT SOURCE_DB_NAME
  TARGET_DB_HOST TARGET_DB_PORT TARGET_DB_NAME
  SOURCE_PUBLICATION_NAME TARGET_SUBSCRIPTION_NAME
  SOURCE_VALIDATION_DB_USER TARGET_VALIDATION_DB_USER
)
for var in "${required_vars[@]}"; do
  [[ -n "${!var:-}" ]] || { echo "ERROR: $var is required in $env_file" >&2; exit 2; }
  [[ "${!var}" != *replace-with* ]] || { echo "ERROR: replace the placeholder value for $var" >&2; exit 2; }
done
[[ -f "$DB_PGPASSFILE_HOST" ]] || { echo "ERROR: PostgreSQL passfile is missing: $DB_PGPASSFILE_HOST" >&2; exit 2; }
[[ -r "$DB_PGPASSFILE_HOST" ]] || { echo "ERROR: PostgreSQL passfile is not readable: $DB_PGPASSFILE_HOST" >&2; exit 2; }
chmod 0600 "$DB_PGPASSFILE_HOST"
validate_ssl() {
  local label="$1" mode="$2" ca_path="$3"
  case "$mode" in
    verify-ca|verify-full)
      [[ -n "$ca_path" ]] || { echo "ERROR: $label CA path is required for sslmode=$mode" >&2; exit 2; }
      [[ -r "$ca_path" ]] || { echo "ERROR: $label CA is not readable: $ca_path" >&2; exit 2; }
      ;;
    require)
      echo "WARNING: $label sslmode=require encrypts traffic but does not verify the server hostname." >&2
      ;;
    disable|allow|prefer)
      echo "WARNING: $label sslmode=$mode can use an unencrypted connection." >&2
      ;;
    *)
      echo "ERROR: $label SSL mode must be disable, allow, prefer, require, verify-ca, or verify-full" >&2
      exit 2
      ;;
  esac
}
validate_ssl source "$SOURCE_DB_SSLMODE" "${SOURCE_DB_SSLROOTCERT_HOST:-}"
validate_ssl target "$TARGET_DB_SSLMODE" "${TARGET_DB_SSLROOTCERT_HOST:-}"

cd "$project_dir"
exec python3 scripts/validate_data.py "$@"
