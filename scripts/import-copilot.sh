#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
require_commands bq

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: $0 path/to/copilot-transactions.csv" >&2
  exit 1
fi

bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" load \
  --replace \
  --source_format=CSV \
  --skip_leading_rows=1 \
  --allow_quoted_newlines \
  "$RAW_DATASET.copilot_transactions" \
  "$1" \
  'transaction_date:STRING,name:STRING,amount:STRING,status:STRING,category:STRING,parent_category:STRING,excluded:STRING,tags:STRING,transaction_type:STRING,account_name:STRING,account_mask:STRING,note:STRING,recurring:STRING'

echo "Copilot transactions imported into ${GCP_PROJECT_ID}.${RAW_DATASET}.copilot_transactions"
