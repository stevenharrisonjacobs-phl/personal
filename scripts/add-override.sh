#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
require_commands bq

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 TRANSACTION_KEY CATEGORY [NOTES]" >&2
  exit 1
fi

transaction_key="$1"
category="$2"
notes="${3:-}"

bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false \
  --parameter="transaction_key:STRING:$transaction_key" \
  --parameter="category:STRING:$category" \
  --parameter="notes:STRING:$notes" \
  "INSERT INTO \`${GCP_PROJECT_ID}.${FINANCE_DATASET}.transaction_overrides\`
     (transaction_key, category, notes, created_at)
   VALUES
     (@transaction_key, @category, NULLIF(@notes, ''), CURRENT_TIMESTAMP());"

