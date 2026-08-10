#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
require_commands bq

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: $0 path/to/read-only-query.sql" >&2
  exit 1
fi

render_sql "$1" | bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false \
  --max_rows="${QUERY_MAX_ROWS:-100000}"
