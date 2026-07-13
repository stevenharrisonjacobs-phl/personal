#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
require_commands bq jq mktemp

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "Usage: $0 candidates.json decisions.jsonl REVIEW_VERSION [session_ai|deterministic_clear]" >&2
  exit 1
fi

candidates_file="$1"
decisions_file="$2"
review_version="$3"
review_method="${4:-session_ai}"

if [[ ! -f "$candidates_file" || ! -f "$decisions_file" ]]; then
  echo "Candidates and decisions files must exist." >&2
  exit 1
fi
if [[ "$review_method" != "session_ai" && "$review_method" != "deterministic_clear" ]]; then
  echo "Unsupported review method: $review_method" >&2
  exit 1
fi

temp_dir="$(mktemp -d)"
stage_table="_onboarding_stage_$(date -u +%Y%m%d%H%M%S)_$$"
stage_ref="$GCP_PROJECT_ID:$GOLD_DATASET.$stage_table"
trap 'bq --project_id="$GCP_PROJECT_ID" rm -f -t "$stage_ref" >/dev/null 2>&1 || true; rm -rf "$temp_dir"' EXIT

jq -e 'type == "array"' "$candidates_file" >/dev/null
jq -s -e '
  all(.[ ];
    (.transaction_key | type == "string" and length > 0) and
    (.is_anomaly | type == "boolean") and
    (.severity | IN("none", "low", "medium", "high", "critical")) and
    (.anomaly_types | type == "array") and
    (.rationale | type == "string" and length > 0 and length <= 500) and
    (.requires_human_review | type == "boolean")
  )
' "$decisions_file" >/dev/null

jq -n -c \
  --slurpfile candidates "$candidates_file" \
  --slurpfile decisions "$decisions_file" '
  ($candidates[0]) as $c |
  ($decisions) as $d |
  if (($c | map(.transaction_key) | unique | length) != ($c | length)) then
    error("duplicate candidate transaction keys")
  elif (($d | map(.transaction_key) | unique | length) != ($d | length)) then
    error("duplicate decision transaction keys")
  elif (($c | map(.transaction_key) | sort) != ($d | map(.transaction_key) | sort)) then
    error("decision keys must exactly match candidate keys")
  else
    $c[] as $row |
    ($d[] | select(.transaction_key == $row.transaction_key)) as $decision |
    {
      transaction_key: $row.transaction_key,
      transaction_date: $row.transaction_date,
      deterministic_flags: ($row.deterministic_flags // []),
      is_anomaly: $decision.is_anomaly,
      severity: $decision.severity,
      anomaly_types: ($decision.anomaly_types // []),
      rationale: $decision.rationale,
      suggested_flow_type: ($decision.suggested_flow_type // null),
      suggested_category_id: ($decision.suggested_category_id // null),
      suggested_vendor_name: ($decision.suggested_vendor_name // null),
      requires_human_review: $decision.requires_human_review
    }
  end
' > "$temp_dir/reviews.jsonl"

review_count="$(wc -l < "$temp_dir/reviews.jsonl" | tr -d ' ')"
if [[ "$review_count" == "0" ]]; then
  echo "No reviews to apply."
  exit 0
fi

bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" load \
  --source_format=NEWLINE_DELIMITED_JSON \
  "$stage_ref" \
  "$temp_dir/reviews.jsonl" \
  "$ROOT_DIR/sql/onboarding_review_schema.json" >/dev/null

bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false \
  --parameter="review_version::${review_version}" \
  --parameter="review_method::${review_method}" \
  --parameter="model::codex-session" \
  --parameter="prompt_version::session-finance-review-v1" \
  "ASSERT NOT EXISTS (
     SELECT 1 FROM \`${GCP_PROJECT_ID}.${GOLD_DATASET}.${stage_table}\`
     WHERE severity NOT IN ('none', 'low', 'medium', 'high', 'critical')
        OR suggested_flow_type IS NOT NULL AND suggested_flow_type NOT IN (
          'expense', 'earned_income', 'investment_income', 'refund_reimbursement',
          'internal_transfer', 'credit_card_payment', 'investment_activity',
          'cash_withdrawal', 'adjustment', 'needs_review'
        )
   ) AS 'Invalid severity or suggested flow type';

   ASSERT NOT EXISTS (
     SELECT 1
     FROM \`${GCP_PROJECT_ID}.${GOLD_DATASET}.${stage_table}\`,
     UNNEST(anomaly_types) AS anomaly_type
     WHERE anomaly_type NOT IN (
       'amount_outlier', 'possible_duplicate', 'new_vendor', 'vendor_mismatch',
       'category_mismatch', 'flow_mismatch', 'unclassified', 'low_confidence',
       'source_ambiguity', 'other'
     )
   ) AS 'Invalid anomaly type';

   ASSERT NOT EXISTS (
     SELECT 1 FROM \`${GCP_PROJECT_ID}.${GOLD_DATASET}.${stage_table}\`
     WHERE (is_anomaly AND (severity = 'none' OR ARRAY_LENGTH(anomaly_types) = 0 OR NOT requires_human_review))
        OR (NOT is_anomaly AND (severity != 'none' OR ARRAY_LENGTH(anomaly_types) > 0))
        OR ('flow_needs_review' IN UNNEST(deterministic_flags) AND NOT requires_human_review)
   ) AS 'Inconsistent anomaly decision';

   ASSERT NOT EXISTS (
     SELECT 1
     FROM \`${GCP_PROJECT_ID}.${GOLD_DATASET}.${stage_table}\` AS s
     LEFT JOIN \`${GCP_PROJECT_ID}.${GOLD_DATASET}.categories\` AS c
       ON c.category_id = s.suggested_category_id AND c.active
     WHERE s.suggested_category_id IS NOT NULL AND c.category_id IS NULL
   ) AS 'Suggested category must be an active canonical category';

   MERGE \`${GCP_PROJECT_ID}.${GOLD_DATASET}.transaction_onboarding_reviews\` AS target
   USING \`${GCP_PROJECT_ID}.${GOLD_DATASET}.${stage_table}\` AS source
   ON target.transaction_key = source.transaction_key
  AND target.review_version = @review_version
   WHEN MATCHED THEN UPDATE SET
     transaction_date = source.transaction_date,
     reviewed_at = CURRENT_TIMESTAMP(),
     review_method = @review_method,
     deterministic_flags = source.deterministic_flags,
     is_anomaly = source.is_anomaly,
     severity = source.severity,
     anomaly_types = source.anomaly_types,
     rationale = source.rationale,
     suggested_flow_type = source.suggested_flow_type,
     suggested_category_id = source.suggested_category_id,
     suggested_vendor_name = source.suggested_vendor_name,
     requires_human_review = source.requires_human_review,
     model = @model,
     response_id = NULL,
     prompt_version = @prompt_version
   WHEN NOT MATCHED THEN INSERT (
     transaction_key, review_version, transaction_date, reviewed_at, review_method,
     deterministic_flags, is_anomaly, severity, anomaly_types, rationale,
     suggested_flow_type, suggested_category_id, suggested_vendor_name,
     requires_human_review, model, response_id, prompt_version
   ) VALUES (
     source.transaction_key, @review_version, source.transaction_date, CURRENT_TIMESTAMP(), @review_method,
     source.deterministic_flags, source.is_anomaly, source.severity, source.anomaly_types, source.rationale,
     source.suggested_flow_type, source.suggested_category_id, source.suggested_vendor_name,
     source.requires_human_review, @model, NULL, @prompt_version
   );" >/dev/null

echo "Applied $review_count $review_method reviews for $review_version."
