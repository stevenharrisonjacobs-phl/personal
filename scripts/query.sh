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

sql="$(render_sql "$1")"
normalized="$(
  printf '%s' "$sql" \
    | tr '\n' ' ' \
    | sed -E 's/--[^;]*//g; s:/\*([^*]|\*+[^*/])*\*/::g' \
    | tr '[:lower:]' '[:upper:]'
)"

if [[ ! "$normalized" =~ ^[[:space:]]*(SELECT|WITH)[[:space:]] ]]; then
  echo "Only SELECT or WITH queries are allowed." >&2
  exit 1
fi
if [[ "$normalized" =~ \;[[:space:]]*[^[:space:]] ]]; then
  echo "Only one statement is allowed." >&2
  exit 1
fi
if [[ "$normalized" =~ (^|[[:space:]])(INSERT|UPDATE|DELETE|MERGE|CREATE|ALTER|DROP|TRUNCATE|EXPORT|CALL|GRANT|REVOKE)([[:space:]]|$) ]]; then
  echo "Mutating SQL is not allowed by this wrapper." >&2
  exit 1
fi

bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false \
  --max_rows=200 \
  "$sql"
