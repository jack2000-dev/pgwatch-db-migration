#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${ENV_FILE:-$project_dir/.env}"

command -v python3 >/dev/null || { echo "ERROR: python3 is required" >&2; exit 2; }
command -v psql >/dev/null || { echo "ERROR: psql is required" >&2; exit 2; }
command -v stdbuf >/dev/null || { echo "ERROR: stdbuf is required" >&2; exit 2; }
command -v docker >/dev/null || { echo "ERROR: docker is required" >&2; exit 2; }
command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 2; }
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
  METRICS_DB_NAME METRICS_DB_USER
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
validation_args=("$@")
report_path=""
for ((i = 0; i < ${#validation_args[@]}; i++)); do
  case "${validation_args[$i]}" in
    --output)
      ((i + 1 < ${#validation_args[@]})) || { echo "ERROR: --output requires a path" >&2; exit 2; }
      report_path="${validation_args[$((i + 1))]}"
      ;;
    --output=*) report_path="${validation_args[$i]#--output=}" ;;
  esac
done
if [[ -z "$report_path" ]]; then
  report_path="validation-reports/data-validation-$(date -u +%Y%m%dT%H%M%SZ).jsonl"
  validation_args+=(--output "$report_path")
fi

set +e
python3 scripts/validate_data.py "${validation_args[@]}"
validation_exit=$?
set -e

validation_status=ERROR
tables=0
source_rows=0
target_rows=0
differences=0
if [[ "$validation_exit" -eq 0 || "$validation_exit" -eq 1 ]] && [[ -f "$report_path" ]]; then
  summary="$(jq -sc 'map(select(.record == "summary")) | last // empty' "$report_path")"
  if [[ -n "$summary" ]]; then
    [[ "$validation_exit" -eq 0 ]] && validation_status=PASS || validation_status=FAIL
    tables="$(jq -r '.tables // 0' <<<"$summary")"
    source_rows="$(jq -r '.source // 0' <<<"$summary")"
    target_rows="$(jq -r '.target // 0' <<<"$summary")"
    differences="$(jq -r '.differences // 0' <<<"$summary")"
  fi
fi

validation_pair="${VALIDATION_MIGRATION_PAIR:-$SOURCE_DB_NAME}"
if ! docker compose --env-file "$env_file" exec -T metrics-db \
  psql -X -qAt -v ON_ERROR_STOP=1 -U "$METRICS_DB_USER" -d "$METRICS_DB_NAME" \
  -v pair="$validation_pair" -v status="$validation_status" \
  -v source_database="$SOURCE_DB_NAME" -v target_database="$TARGET_DB_NAME" \
  -v publication="$SOURCE_PUBLICATION_NAME" -v subscription="$TARGET_SUBSCRIPTION_NAME" \
  -v tables="$tables" -v source_rows="$source_rows" -v target_rows="$target_rows" \
  -v differences="$differences" \
  -c "INSERT INTO cutover_validation (migration_pair, status, source_database, target_database, publication, subscription, tables, source_rows, target_rows, differences) VALUES (:'pair', :'status', :'source_database', :'target_database', :'publication', :'subscription', :'tables'::bigint, :'source_rows'::bigint, :'target_rows'::bigint, :'differences'::bigint);"; then
  echo "ERROR: data comparison finished but its cutover status could not be recorded" >&2
  exit 2
fi

exit "$validation_exit"
