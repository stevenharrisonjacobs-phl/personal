#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

for script in "$SCRIPT_DIR"/*.sh; do
  bash -n "$script"
done

if [[ ! -f "$ROOT_DIR/.env" ]]; then
  echo "Shell syntax passed. Copy .env.example to .env to run cloud checks."
  exit 0
fi

load_env
require_commands bq

required_tables=(
  "$GCP_PROJECT_ID:$RAW_DATASET.transactions_external"
  "$GCP_PROJECT_ID:$RAW_DATASET.balance_history_external"
  "$GCP_PROJECT_ID:$RAW_DATASET.copilot_transactions"
  "$GCP_PROJECT_ID:$FINANCE_DATASET.transactions"
  "$GCP_PROJECT_ID:$FINANCE_DATASET.balance_history"
  "$GCP_PROJECT_ID:$FINANCE_DATASET.classification_rules"
  "$GCP_PROJECT_ID:$FINANCE_DATASET.transaction_overrides"
  "$GCP_PROJECT_ID:$FINANCE_DATASET.v_transactions_classified"
  "$GCP_PROJECT_ID:$FINANCE_DATASET.v_spending"
  "$GCP_PROJECT_ID:$FINANCE_DATASET.v_current_balances"
  "$GCP_PROJECT_ID:$FINANCE_DATASET.v_monthly_net_worth"
  "$GCP_PROJECT_ID:$GOLD_DATASET.vendor_rules"
  "$GCP_PROJECT_ID:$GOLD_DATASET.categories"
  "$GCP_PROJECT_ID:$GOLD_DATASET.category_aliases"
  "$GCP_PROJECT_ID:$GOLD_DATASET.epic_definitions"
  "$GCP_PROJECT_ID:$GOLD_DATASET.epic_transactions"
  "$GCP_PROJECT_ID:$GOLD_DATASET.epics"
  "$GCP_PROJECT_ID:$GOLD_DATASET.vendor_aliases"
  "$GCP_PROJECT_ID:$GOLD_DATASET.transaction_vendor_overrides"
  "$GCP_PROJECT_ID:$GOLD_DATASET.transactions_base"
  "$GCP_PROJECT_ID:$GOLD_DATASET.copilot_transaction_matches"
  "$GCP_PROJECT_ID:$GOLD_DATASET.transactions"
  "$GCP_PROJECT_ID:$GOLD_DATASET.transaction_flow_review"
  "$GCP_PROJECT_ID:$GOLD_DATASET.transaction_onboarding_reviews"
  "$GCP_PROJECT_ID:$GOLD_DATASET.transaction_onboarding_runs"
  "$GCP_PROJECT_ID:$GOLD_DATASET.transaction_onboarding_latest"
  "$GCP_PROJECT_ID:$GOLD_DATASET.transaction_anomaly_review_queue"
  "$GCP_PROJECT_ID:$GOLD_DATASET.ai_anomaly_review_queue"
  "$GCP_PROJECT_ID:$GOLD_DATASET.vendor_canonical_review"
  "$GCP_PROJECT_ID:$GOLD_DATASET.vendors"
  "$GCP_PROJECT_ID:$GOLD_DATASET.accounts"
)

for table_ref in "${required_tables[@]}"; do
  if ! table_exists "$table_ref"; then
    echo "Missing BigQuery object: $table_ref" >&2
    exit 1
  fi
done

bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false \
  "SELECT
     (SELECT COUNT(*) FROM \`${GCP_PROJECT_ID}.${FINANCE_DATASET}.transactions\`) AS transactions,
     (SELECT COUNT(*) FROM \`${GCP_PROJECT_ID}.${FINANCE_DATASET}.balance_history\`) AS balance_records,
     (SELECT COUNT(*) FROM \`${GCP_PROJECT_ID}.${FINANCE_DATASET}.v_transactions_classified\` WHERE category = 'Uncategorized') AS uncategorized,
     (SELECT COUNT(*) FROM \`${GCP_PROJECT_ID}.${GOLD_DATASET}.vendors\`) AS vendors,
     (SELECT COUNT(*) FROM \`${GCP_PROJECT_ID}.${GOLD_DATASET}.accounts\`) AS accounts;"

bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false \
  "SELECT
     (SELECT COUNT(*) FROM \`${GCP_PROJECT_ID}.${GOLD_DATASET}.epics\`) AS epics,
     (SELECT COUNT(*) FROM \`${GCP_PROJECT_ID}.${GOLD_DATASET}.epic_transactions\`) AS epic_transactions,
     (SELECT COUNTIF(match_status = 'matched') FROM \`${GCP_PROJECT_ID}.${GOLD_DATASET}.epic_transactions\`) AS matched_to_tiller,
     (SELECT COUNTIF(match_status != 'matched') FROM \`${GCP_PROJECT_ID}.${GOLD_DATASET}.epic_transactions\`) AS retained_unlinked;"

bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false \
  "SELECT
     (SELECT COUNT(*) FROM \`${GCP_PROJECT_ID}.${GOLD_DATASET}.transactions\`) AS transactions,
     (SELECT COUNT(DISTINCT transaction_key) FROM \`${GCP_PROJECT_ID}.${GOLD_DATASET}.transactions\`) AS distinct_transaction_keys,
     (SELECT COUNTIF(flow_type = 'needs_review') FROM \`${GCP_PROJECT_ID}.${GOLD_DATASET}.transactions\`) AS flow_review_queue;"

echo "Validation passed."
