#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
require_commands bq

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 TRANSACTION_KEY VENDOR_NAME [NOTES]" >&2
  exit 1
fi

transaction_key="$1"
vendor_name="$2"
notes="${3:-}"

bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false \
  --parameter="transaction_key:STRING:$transaction_key" \
  --parameter="vendor_name:STRING:$vendor_name" \
  --parameter="notes:STRING:$notes" \
  "INSERT INTO \`${GCP_PROJECT_ID}.${GOLD_DATASET}.transaction_vendor_overrides\`
     (transaction_key, vendor_name, notes, created_at)
   VALUES
     (@transaction_key, @vendor_name, NULLIF(@notes, ''), CURRENT_TIMESTAMP());"

