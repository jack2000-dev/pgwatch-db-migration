#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${ENV_FILE:-$project_dir/.env}"
[[ -f "$env_file" ]] || { echo "ERROR: missing $env_file" >&2; exit 1; }

cd "$project_dir"
docker compose --env-file "$env_file" down
echo "Stack stopped; metrics and Grafana volumes were preserved."
echo "To remove monitoring data too: docker compose --env-file .env down --volumes"

