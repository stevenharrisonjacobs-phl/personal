#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
require_commands bq

if [[ $# -lt 4 || $# -gt 5 ]]; then
  cat >&2 <<'USAGE'
Usage: add-amortization.sh TARGET_TYPE TARGET_ID START_DATE END_DATE [LABEL]

  TARGET_TYPE   txn | epic
  TARGET_ID     transaction_key (txn) or epic_name (epic)
  START_DATE    YYYY-MM-DD  first month the cost applies to
  END_DATE      YYYY-MM-DD  last month the cost applies to (inclusive)
  LABEL         optional human label, e.g. "Exterior paint, 5-year life"

Spreads the cost evenly across the inclusive months from START to END in
gold.v_spending_amortized. Re-running for the same target replaces the schedule.

Examples:
  add-amortization.sh txn abc123def 2026-09-01 2031-08-01 "House paint, 5yr"
  add-amortization.sh epic "Kitchen Reno" 2026-06-01 2036-05-01 "Kitchen, 10yr"
USAGE
  exit 1
fi

target_type="$1"
target_id="$2"
start_date="$3"
end_date="$4"
label="${5:-}"

case "$target_type" in
  txn)  key_col="transaction_key" ;;
  epic) key_col="epic_name" ;;
  *) echo "TARGET_TYPE must be 'txn' or 'epic'." >&2; exit 1 ;;
esac

for d in "$start_date" "$end_date"; do
  [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "Dates must be YYYY-MM-DD (got '$d')." >&2; exit 1; }
done

amortization_id="${target_type}:${target_id}"

bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false \
  --parameter="amortization_id:STRING:$amortization_id" \
  --parameter="target_id:STRING:$target_id" \
  --parameter="start_date:DATE:$start_date" \
  --parameter="end_date:DATE:$end_date" \
  --parameter="label:STRING:$label" \
  "ASSERT DATE(@end_date) >= DATE(@start_date) AS 'END_DATE must be on or after START_DATE';
   DELETE FROM \`${GCP_PROJECT_ID}.${GOLD_DATASET}.amortization_schedule\`
     WHERE amortization_id = @amortization_id;
   INSERT INTO \`${GCP_PROJECT_ID}.${GOLD_DATASET}.amortization_schedule\`
     (amortization_id, ${key_col}, start_date, end_date, label, notes, enabled, created_at)
   VALUES
     (@amortization_id, @target_id, DATE(@start_date), DATE(@end_date),
      NULLIF(@label, ''), 'Added via add-amortization.sh', TRUE, CURRENT_TIMESTAMP());"
