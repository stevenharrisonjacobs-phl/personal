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

# Read-only is now ENFORCED, not just the usage string. This runner is on the
# unattended 6am agent's allowlist under a BigQuery-admin service account, so
# "convenient runner" must not double as a DML path: one statement, and it
# must be SELECT/WITH. Writes go through their owning scripts (add-*.sh,
# checkin-write.sh, deploy.sh), which call bq themselves.
rendered="$(render_sql "$1")"
QUERY_SQL="$rendered" python3 - <<'PYEOF'
import os, re, sys
sql = os.environ["QUERY_SQL"]
stripped = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)
stripped = re.sub(r"--[^\n]*", " ", stripped).strip()
if not re.match(r"^(SELECT|WITH)\b", stripped, re.I):
    sys.exit("query.sh: refused — only a SELECT/WITH statement may run here")
body = stripped.rstrip().rstrip(";")
if ";" in body:
    sys.exit("query.sh: refused — only one SQL statement may run here")
PYEOF

printf '%s' "$rendered" | bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false \
  --max_rows="${QUERY_MAX_ROWS:-100000}"
