#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
require_commands bq jq mktemp

sheet_uri="https://docs.google.com/spreadsheets/d/${TILLER_SHEET_ID}"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

if ! bq --project_id="$GCP_PROJECT_ID" show "$GCP_PROJECT_ID:$RAW_DATASET" >/dev/null 2>&1; then
  bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" mk --dataset "$RAW_DATASET"
fi
if ! bq --project_id="$GCP_PROJECT_ID" show "$GCP_PROJECT_ID:$FINANCE_DATASET" >/dev/null 2>&1; then
  bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" mk --dataset "$FINANCE_DATASET"
fi
if ! bq --project_id="$GCP_PROJECT_ID" show "$GCP_PROJECT_ID:$GOLD_DATASET" >/dev/null 2>&1; then
  bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" mk --dataset "$GOLD_DATASET"
fi

make_definition() {
  local tab_name="$1"
  local destination="$2"
  jq -n \
    --arg uri "$sheet_uri" \
    --arg tab "$tab_name" \
    '{
      autodetect: true,
      sourceFormat: "GOOGLE_SHEETS",
      sourceUris: [$uri],
      googleSheetsOptions: {
        range: $tab,
        skipLeadingRows: "1"
      }
    }' > "$destination"
}

upsert_external_table() {
  local table_name="$1"
  local definition_file="$2"
  local table_ref="$GCP_PROJECT_ID:$RAW_DATASET.$table_name"
  if table_exists "$table_ref"; then
    bq --project_id="$GCP_PROJECT_ID" update \
      --external_table_definition="$definition_file" \
      "$table_ref"
  else
    bq --project_id="$GCP_PROJECT_ID" mk \
      --external_table_definition="$definition_file" \
      "$table_ref"
  fi
}

make_definition "$TRANSACTIONS_TAB" "$temp_dir/transactions.json"
make_definition "$BALANCE_HISTORY_TAB" "$temp_dir/balance_history.json"
upsert_external_table transactions_external "$temp_dir/transactions.json"
upsert_external_table balance_history_external "$temp_dir/balance_history.json"

render_sql "$ROOT_DIR/sql/refresh.sql" > "$temp_dir/refresh.sql"
render_sql "$ROOT_DIR/sql/model.sql" > "$temp_dir/model.sql"
render_sql "$ROOT_DIR/sql/categories.sql" > "$temp_dir/categories.sql"
render_sql "$ROOT_DIR/sql/epics.sql" > "$temp_dir/epics.sql"
render_sql "$ROOT_DIR/sql/gold.sql" > "$temp_dir/gold.sql"
render_sql "$ROOT_DIR/sql/reviewer.sql" > "$temp_dir/reviewer.sql"

bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false < "$temp_dir/refresh.sql"
bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false < "$temp_dir/model.sql"
bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false < "$temp_dir/categories.sql"
bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false < "$temp_dir/epics.sql"
bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false < "$temp_dir/gold.sql"
bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false < "$temp_dir/reviewer.sql"

schedule_params="$(jq -n \
  --rawfile query "$temp_dir/refresh.sql" \
  '{query: $query}')"

existing_schedule="$(
  bq --project_id="$GCP_PROJECT_ID" ls \
    --transfer_config --transfer_location="$BQ_LOCATION" --format=json 2>/dev/null \
    | jq -r '.[] | select(.displayName == "Tiller hourly mirror") | .name' \
    | head -1
)"

if [[ -z "$existing_schedule" ]]; then
  bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" mk \
    --transfer_config \
    --display_name="Tiller hourly mirror" \
    --data_source=scheduled_query \
    --schedule="$SYNC_SCHEDULE" \
    --params="$schedule_params"
else
  bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" update \
    --transfer_config \
    --schedule="$SYNC_SCHEDULE" \
    --params="$schedule_params" \
    "$existing_schedule"
fi

echo "Deployment complete. Run ./scripts/validate.sh"
