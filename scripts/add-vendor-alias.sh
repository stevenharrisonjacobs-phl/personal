#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
require_commands bq

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 ALIAS CANONICAL_VENDOR_NAME [NOTES]" >&2
  exit 1
fi

alias_name="$1"
canonical_vendor_name="$2"
notes="${3:-}"

bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false \
  --parameter="alias_name:STRING:$alias_name" \
  --parameter="canonical_vendor_name:STRING:$canonical_vendor_name" \
  --parameter="notes:STRING:$notes" \
  "DECLARE normalized_alias_key STRING DEFAULT REGEXP_REPLACE(LOWER(@alias_name), r'[^a-z0-9]+', '');
   DELETE FROM \`${GCP_PROJECT_ID}.${GOLD_DATASET}.vendor_aliases\` WHERE alias_key = normalized_alias_key;
   INSERT INTO \`${GCP_PROJECT_ID}.${GOLD_DATASET}.vendor_aliases\`
     (alias_key, alias_name, canonical_vendor_name, notes, enabled, created_at)
   VALUES
     (normalized_alias_key, @alias_name, @canonical_vendor_name, NULLIF(@notes, ''), TRUE, CURRENT_TIMESTAMP());"
