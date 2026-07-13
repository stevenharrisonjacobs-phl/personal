#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
require_commands bq

if [[ $# -lt 4 || $# -gt 5 ]]; then
  echo "Usage: $0 RULE_ID PRIORITY DESCRIPTION_REGEX CATEGORY [SUBCATEGORY]" >&2
  exit 1
fi

rule_id="$1"
priority="$2"
description_regex="$3"
category="$4"
subcategory="${5:-}"

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
  "DELETE FROM \`${GCP_PROJECT_ID}.${FINANCE_DATASET}.classification_rules\` WHERE rule_id = @rule_id;
   INSERT INTO \`${GCP_PROJECT_ID}.${FINANCE_DATASET}.classification_rules\`
     (rule_id, priority, description_regex, direction, category, subcategory, enabled, created_at)
   VALUES
     (@rule_id, @priority, @description_regex, 'expense', @category, NULLIF(@subcategory, ''), TRUE, CURRENT_TIMESTAMP());"

