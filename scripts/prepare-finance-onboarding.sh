#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
require_commands bq jq uuidgen

review_version="${1:-session-v1}"
lookback_days="${2:-14}"
run_dir="${3:-$ROOT_DIR/.context/finance-onboarding/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$run_dir"

render_sql "$ROOT_DIR/sql/onboarding_candidates.sql" > "$run_dir/query.sql"
bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false \
  --format=json \
  --max_rows=100000 \
  --parameter="review_version::${review_version}" \
  --parameter="lookback_days:INT64:${lookback_days}" \
  "$(<"$run_dir/query.sql")" > "$run_dir/all.json"

jq '[.[] | select((.deterministic_flags // []) | length == 0)]' \
  "$run_dir/all.json" > "$run_dir/clear.json"
jq '[.[] | select((.deterministic_flags // []) | length > 0)]' \
  "$run_dir/all.json" > "$run_dir/candidates.json"

clear_count="$(jq 'length' "$run_dir/clear.json")"
candidate_count="$(jq 'length' "$run_dir/candidates.json")"
discovered_count="$((clear_count + candidate_count))"

if (( clear_count > 0 )); then
  jq -c '.[] | {
    transaction_key,
    is_anomaly: false,
    severity: "none",
    anomaly_types: [],
    rationale: "No deterministic anomaly flags were triggered.",
    suggested_flow_type: null,
    suggested_category_id: null,
    suggested_vendor_name: null,
    requires_human_review: false
  }' "$run_dir/clear.json" > "$run_dir/clear-decisions.jsonl"
  "$SCRIPT_DIR/apply-finance-onboarding.sh" \
    "$run_dir/clear.json" "$run_dir/clear-decisions.jsonl" \
    "$review_version" deterministic_clear
else
  : > "$run_dir/clear-decisions.jsonl"
fi

jq -n \
  --arg run_id "$(uuidgen | tr '[:upper:]' '[:lower:]')" \
  --arg review_version "$review_version" \
  --argjson lookback_days "$lookback_days" \
  --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg run_dir "$run_dir" \
  --argjson discovered "$discovered_count" \
  --argjson clear "$clear_count" \
  --argjson candidates "$candidate_count" \
  '{run_id:$run_id, review_version:$review_version, lookback_days:$lookback_days, started_at:$started_at,
    run_dir:$run_dir, discovered_count:$discovered,
    deterministic_clear_count:$clear, candidate_count:$candidates}' \
  > "$run_dir/state.json"

echo "Prepared onboarding run: $run_dir"
echo "Discovered: $discovered_count; deterministic clear: $clear_count; session review: $candidate_count"
echo "Candidate file: $run_dir/candidates.json"
echo "State file: $run_dir/state.json"
