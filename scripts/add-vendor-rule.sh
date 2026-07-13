#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
require_commands bq

if [[ $# -lt 4 || $# -gt 5 ]]; then
  echo "Usage: $0 RULE_ID PRIORITY DESCRIPTION_REGEX VENDOR_NAME [NOTES]" >&2
  exit 1
fi

rule_id="$1"
priority="$2"
description_regex="$3"
vendor_name="$4"
notes="${5:-}"

if [[ ! "$priority" =~ ^[0-9]+$ ]]; then
  echo "Priority must be a non-negative integer." >&2
  exit 1
fi

bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false \
  --parameter="rule_id:STRING:$rule_id" \
  --parameter="priority:INT64:$priority" \
  --parameter="description_regex:STRING:$description_regex" \
  --parameter="vendor_name:STRING:$vendor_name" \
  --parameter="notes:STRING:$notes" \
  "SELECT IF(NOT REGEXP_CONTAINS('', @description_regex), TRUE, TRUE);
   DELETE FROM \`${GCP_PROJECT_ID}.${GOLD_DATASET}.vendor_rules\` WHERE rule_id = @rule_id;
   INSERT INTO \`${GCP_PROJECT_ID}.${GOLD_DATASET}.vendor_rules\`
     (rule_id, priority, description_regex, vendor_name, notes, enabled, created_at)
   VALUES
     (@rule_id, @priority, @description_regex, @vendor_name, NULLIF(@notes, ''), TRUE, CURRENT_TIMESTAMP());"

