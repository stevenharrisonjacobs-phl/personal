#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
require_commands bq

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 TRANSACTION_KEY FLOW_TYPE [NOTES]" >&2
  echo "  FLOW_TYPE e.g. earned_income | investment_income | internal_transfer |" >&2
  echo "                capital_proceeds | refund_reimbursement | expense" >&2
  exit 1
fi

transaction_key="$1"
flow_type="$2"
notes="${3:-}"

bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false \
  --parameter="transaction_key:STRING:$transaction_key" \
  --parameter="flow_type:STRING:$flow_type" \
  --parameter="notes:STRING:$notes" \
  "INSERT INTO \`${GCP_PROJECT_ID}.${GOLD_DATASET}.transaction_flow_overrides\`
     (transaction_key, flow_type, notes, created_at)
   VALUES
     (@transaction_key, @flow_type, NULLIF(@notes, ''), CURRENT_TIMESTAMP());"
