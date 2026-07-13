#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
require_commands bq jq

if [[ $# -ne 2 || ! -f "$1" || ! -f "$2" ]]; then
  echo "Usage: $0 state.json session-decisions.jsonl" >&2
  exit 1
fi

state_file="$1"
decisions_file="$2"
run_id="$(jq -r '.run_id' "$state_file")"
review_version="$(jq -r '.review_version' "$state_file")"
started_at="$(jq -r '.started_at' "$state_file")"
discovered="$(jq -r '.discovered_count' "$state_file")"
clear_count="$(jq -r '.deterministic_clear_count' "$state_file")"
candidate_count="$(jq -r '.candidate_count' "$state_file")"
reviewed_count="$(jq -s 'length' "$decisions_file")"
human_count="$(jq -s '[.[] | select(.requires_human_review)] | length' "$decisions_file")"

if [[ "$reviewed_count" != "$candidate_count" ]]; then
  echo "Expected $candidate_count session decisions but found $reviewed_count." >&2
  exit 1
fi

bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
  --use_legacy_sql=false \
  --parameter="run_id::${run_id}" \
  --parameter="review_version::${review_version}" \
  --parameter="started_at:TIMESTAMP:${started_at}" \
  --parameter="discovered:INT64:${discovered}" \
  --parameter="clear_count:INT64:${clear_count}" \
  --parameter="candidate_count:INT64:${candidate_count}" \
  --parameter="reviewed_count:INT64:${reviewed_count}" \
  --parameter="human_count:INT64:${human_count}" \
  "INSERT INTO \`${GCP_PROJECT_ID}.${GOLD_DATASET}.transaction_onboarding_runs\` (
     run_id, review_version, started_at, completed_at, status,
     discovered_transaction_count, deterministic_clear_count,
     ai_candidate_count, ai_reviewed_count, human_review_count,
     error_message, model
   ) VALUES (
     @run_id, @review_version, @started_at, CURRENT_TIMESTAMP(), 'succeeded',
     @discovered, @clear_count, @candidate_count, @reviewed_count, @human_count,
     NULL, 'codex-session'
   );" >/dev/null

echo "Completed $run_id: $discovered onboarded, $reviewed_count session-reviewed, $human_count queued."
