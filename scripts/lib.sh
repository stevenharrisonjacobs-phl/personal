#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

load_env() {
  if [[ ! -f "$ROOT_DIR/.env" ]]; then
    echo "Missing .env. Copy .env.example to .env and fill it in." >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"
  set +a

  : "${GCP_PROJECT_ID:?Set GCP_PROJECT_ID in .env}"
  : "${TILLER_SHEET_ID:?Set TILLER_SHEET_ID in .env}"
  : "${BQ_LOCATION:=US}"
  : "${RAW_DATASET:=tiller_raw}"
  : "${FINANCE_DATASET:=finance}"
  : "${GOLD_DATASET:=gold}"
  : "${TRANSACTIONS_TAB:=Transactions}"
  : "${BALANCE_HISTORY_TAB:=Balance History}"
  : "${SYNC_SCHEDULE:=every 1 hours}"

  if [[ "$GCP_PROJECT_ID" == "your-tiller-finance-project" ]]; then
    echo "GCP_PROJECT_ID still has the example value. Edit and save .env before continuing." >&2
    exit 1
  fi
  if [[ "$TILLER_SHEET_ID" == "your-google-sheet-id" ]]; then
    echo "TILLER_SHEET_ID still has the example value. Edit and save .env before continuing." >&2
    exit 1
  fi
  if [[ "${BILLING_ACCOUNT_ID:-}" == "000000-000000-000000" ]]; then
    echo "BILLING_ACCOUNT_ID still has the example value. Edit and save .env before continuing." >&2
    exit 1
  fi
}

require_commands() {
  local command_name
  for command_name in "$@"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "Required command not found: $command_name" >&2
      exit 1
    fi
  done
}

render_sql() {
  local sql_file="$1"
  sed \
    -e "s/__PROJECT_ID__/${GCP_PROJECT_ID}/g" \
    -e "s/__RAW_DATASET__/${RAW_DATASET}/g" \
    -e "s/__FINANCE_DATASET__/${FINANCE_DATASET}/g" \
    -e "s/__GOLD_DATASET__/${GOLD_DATASET}/g" \
    "$sql_file"
}

table_exists() {
  local table_ref="$1"
  bq --project_id="$GCP_PROJECT_ID" show "$table_ref" >/dev/null 2>&1
}
