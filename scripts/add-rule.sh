#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
require_commands bq

if [[ $# -lt 4 || $# -gt 7 ]]; then
  echo "Usage: $0 RULE_ID PRIORITY DESCRIPTION_REGEX CATEGORY [SUBCATEGORY] [MIN_AMOUNT] [MAX_AMOUNT]" >&2
  echo "  MIN/MAX_AMOUNT bound |amount|; use '' to leave a bound open." >&2
  exit 1
fi

rule_id="$1"
priority="$2"
description_regex="$3"
category="$4"
subcategory="${5:-}"
min_amount="${6:-}"
max_amount="${7:-}"

if [[ ! "$priority" =~ ^[0-9]+$ ]]; then
  echo "Priority must be a non-negative integer." >&2
  exit 1
fi

bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false \
  --parameter="rule_id:STRING:$rule_id" \
  --parameter="priority:INT64:$priority" \
  --parameter="description_regex:STRING:$description_regex" \
  --parameter="category:STRING:$category" \
  --parameter="subcategory:STRING:$subcategory" \
  --parameter="min_amount:NUMERIC:$min_amount" \
  --parameter="max_amount:NUMERIC:$max_amount" \
  "DELETE FROM \`${GCP_PROJECT_ID}.${FINANCE_DATASET}.classification_rules\` WHERE rule_id = @rule_id;
   INSERT INTO \`${GCP_PROJECT_ID}.${FINANCE_DATASET}.classification_rules\`
     (rule_id, priority, description_regex, direction, category, subcategory,
      min_absolute_amount, max_absolute_amount, enabled, created_at)
   VALUES
     (@rule_id, @priority, @description_regex, 'expense', @category, NULLIF(@subcategory, ''),
      @min_amount, @max_amount, TRUE, CURRENT_TIMESTAMP());"

