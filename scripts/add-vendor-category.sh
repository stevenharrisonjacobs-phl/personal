#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
require_commands bq

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 VENDOR_NAME CATEGORY_ID [NOTES]" >&2
  echo "  Pins a canonical vendor to one category (overrides the upstream" >&2
  echo "  per-transaction category). VENDOR_NAME must be the resolved vendor_name" >&2
  echo "  (see gold.vendors); CATEGORY_ID must exist in gold.categories." >&2
  exit 1
fi

vendor_name="$1"
category_id="$2"
notes="${3:-}"

bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false \
  --parameter="vendor_name:STRING:$vendor_name" \
  --parameter="category_id:STRING:$category_id" \
  --parameter="notes:STRING:$notes" \
  "ASSERT EXISTS(SELECT 1 FROM \`${GCP_PROJECT_ID}.${GOLD_DATASET}.categories\` WHERE category_id = @category_id AND active)
     AS 'category_id not found in gold.categories';
   DELETE FROM \`${GCP_PROJECT_ID}.${GOLD_DATASET}.vendor_category_map\` WHERE vendor_name = @vendor_name;
   INSERT INTO \`${GCP_PROJECT_ID}.${GOLD_DATASET}.vendor_category_map\`
     (vendor_name, category_id, notes, enabled, created_at)
   VALUES
     (@vendor_name, @category_id, NULLIF(@notes, ''), TRUE, CURRENT_TIMESTAMP());"
