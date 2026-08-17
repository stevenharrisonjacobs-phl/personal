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

# Re-declare every external column as STRING.
#
# Autodetect samples the sheet and guesses types, which makes the mirror
# hostage to a single cell: on 2026-08-12 Tiller put a non-numeric value in
# "Account #", a column autodetect had typed INT64, and EVERY hourly run failed
# with "Could not convert value to integer. Row 25; Col 6" for five days. The
# mirror simply stopped, and nothing said so.
#
# refresh.sql does not care: it reads each row via TO_JSON_STRING and pulls
# every field with JSON_VALUE, then SAFE_CASTs. So the declared types buy
# nothing and can only break things. Autodetect still runs first, purely to
# DISCOVER the column names, which keeps the README's promise that the sheet's
# columns may be reordered or extended freely.
pin_external_schema_to_string() {
  local table_name="$1"
  local tab_name="$2"
  local table_ref="$GCP_PROJECT_ID:$RAW_DATASET.$table_name"
  local schema_file="$temp_dir/${table_name}_schema.json"
  local definition_file="$temp_dir/${table_name}_string.json"

  if ! bq --project_id="$GCP_PROJECT_ID" show --schema --format=prettyjson "$table_ref" \
       > "$schema_file" 2>/dev/null; then
    echo "Could not read schema for $table_ref; leaving autodetected types." >&2
    return 0
  fi

  jq -n \
    --arg uri "$sheet_uri" \
    --arg tab "$tab_name" \
    --slurpfile detected "$schema_file" \
    '{
      autodetect: false,
      sourceFormat: "GOOGLE_SHEETS",
      sourceUris: [$uri],
      googleSheetsOptions: {
        range: $tab,
        skipLeadingRows: "1"
      },
      schema: {
        fields: [$detected[0][] | {name: .name, type: "STRING"}]
      }
    }' > "$definition_file"

  bq --project_id="$GCP_PROJECT_ID" update \
    --external_table_definition="$definition_file" \
    "$table_ref"
  echo "Pinned $table_name columns to STRING (autodetect off)."
}

make_definition "$TRANSACTIONS_TAB" "$temp_dir/transactions.json"
make_definition "$BALANCE_HISTORY_TAB" "$temp_dir/balance_history.json"
upsert_external_table transactions_external "$temp_dir/transactions.json"
upsert_external_table balance_history_external "$temp_dir/balance_history.json"

# Autodetect above discovered the column NAMES; now drop its type guesses.
pin_external_schema_to_string transactions_external "$TRANSACTIONS_TAB"
pin_external_schema_to_string balance_history_external "$BALANCE_HISTORY_TAB"

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
