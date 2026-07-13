#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
require_commands gcloud bq jq

: "${BILLING_ACCOUNT_ID:?Set BILLING_ACCOUNT_ID in .env}"
: "${GCP_PROJECT_NAME:=Tiller Finance}"

active_account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -1)"
if [[ -z "$active_account" ]]; then
  echo "No active Google Cloud login. Run: gcloud auth login --enable-gdrive-access" >&2
  exit 1
fi

if [[ "$active_account" == *gserviceaccount.com ]]; then
  echo "The active Cloud CLI identity is a service account: $active_account" >&2
  echo "Run 'gcloud auth login --enable-gdrive-access' as the Google user who owns the sheet and billing account." >&2
  exit 1
fi

if ! gcloud projects describe "$GCP_PROJECT_ID" >/dev/null 2>&1; then
  create_args=("$GCP_PROJECT_ID" "--name=$GCP_PROJECT_NAME")
  if [[ -n "${GCP_FOLDER_ID:-}" ]]; then
    create_args+=("--folder=$GCP_FOLDER_ID")
  elif [[ -n "${GCP_ORGANIZATION_ID:-}" ]]; then
    create_args+=("--organization=$GCP_ORGANIZATION_ID")
  fi
  gcloud projects create "${create_args[@]}"
fi

gcloud billing projects link "$GCP_PROJECT_ID" --billing-account="$BILLING_ACCOUNT_ID"
gcloud services enable \
  bigquery.googleapis.com \
  bigquerydatatransfer.googleapis.com \
  drive.googleapis.com \
  sheets.googleapis.com \
  iam.googleapis.com \
  --project="$GCP_PROJECT_ID"

echo
echo "Project and APIs are ready."
echo "Run: ./scripts/deploy.sh"
