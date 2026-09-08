#!/usr/bin/env bash
# checkin-write.sh — the ONLY writer for finance.checkin_reports.
#
# The generating agent composes a payload; this script validates and lands it.
# An LLM composing INSERT statements each morning is itself an integrity
# failure path (schema drift, quoting bugs, key omission), so the write is
# deterministic and parameterized — the agent never touches SQL here.
#
#   checkin-write.sh success <payload.json>
#       payload: {run_ts, consumed_checkpoint, window_start, window_end,
#                 sources:{mirror|vantage|live_costs|mercury:
#                            {window_start,window_end,status,total,note}},
#                 totals:{personal_cash,mercury_cash,cloud_billed,cloud_live},
#                 report_md}
#       Timestamps are RFC3339/ISO-8601 UTC strings.
#
#   checkin-write.sh failed --reason "<one line>"
#       Wrapper-owned failure recording: needs NO composed artifacts.
#       Resolves the checkpoint itself and writes a minimal status='failed'
#       row whose window is zero-length, so it can never advance anything.
#
# Integrity contract:
#   * MERGE matches ONLY status='success' rows for the same window_start, so
#     a double fire (calendar + wake, manual + scheduled) lands zero or one
#     success row — and a failed row never blocks a later success.
#   * The checkpoint is re-resolved immediately before the write; if it moved
#     since the payload was composed, the write aborts loudly.
#   * Append-only: no UPDATE path exists here. Recovery is BQ time travel.
#   * Content checks: report_md under the length cap, and no
#     account-number-like digit runs (masked forms like ****1234 pass).
#   * Headline totals are recomputed from the per-source payload and the
#     write refuses on mismatch — served numbers always trace to source pulls.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
load_env
require_commands bq python3

TABLE="\`${GCP_PROJECT_ID}.${FINANCE_DATASET}.checkin_reports\`"
MODE="${1:-}"

resolve_checkpoint() {
  bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" --format=csv query \
    --use_legacy_sql=false --quiet \
    "SELECT IFNULL(FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', MAX(window_end)), 'none')
     FROM ${TABLE} WHERE status = 'success'" | tail -1
}

case "$MODE" in
  success)
    PAYLOAD="${2:?usage: checkin-write.sh success <payload.json>}"
    [[ -f "$PAYLOAD" ]] || { echo "checkin-write: payload not found: $PAYLOAD" >&2; exit 1; }

    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT

    # Validate shape, windows, contiguity, content rules, and totals via the
    # tested module (tests/test_checkin_validate.py). Writes one file per bq
    # parameter into $tmp_dir, all timestamps canonicalized to %Y-%m-%dT%H:%M:%SZ
    # so the checkpoint string comparison below is sound.
    python3 "$SCRIPT_DIR/checkin_validate.py" "$PAYLOAD" "$tmp_dir"

    # Abort if the checkpoint moved since the payload was composed — another
    # run landed between resolution and write.
    live_checkpoint="$(resolve_checkpoint)"
    payload_checkpoint="$(<"$tmp_dir/consumed_checkpoint")"
    if [[ "$live_checkpoint" != "$payload_checkpoint" ]]; then
      echo "checkin-write: checkpoint moved (payload consumed $payload_checkpoint, live is $live_checkpoint); refusing" >&2
      exit 2
    fi

    ckpt_param="$(<"$tmp_dir/consumed_checkpoint")"
    [[ "$ckpt_param" == "none" ]] && ckpt_param=""

    bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
      --use_legacy_sql=false --quiet \
      --parameter="run_ts:TIMESTAMP:$(<"$tmp_dir/run_ts")" \
      --parameter="consumed_checkpoint:STRING:${ckpt_param}" \
      --parameter="window_start:TIMESTAMP:$(<"$tmp_dir/window_start")" \
      --parameter="window_end:TIMESTAMP:$(<"$tmp_dir/window_end")" \
      --parameter="sources:STRING:$(<"$tmp_dir/sources")" \
      --parameter="totals:STRING:$(<"$tmp_dir/totals")" \
      --parameter="report_md:STRING:$(<"$tmp_dir/report_md")" \
      "MERGE ${TABLE} T
       USING (SELECT @window_start AS window_start) S
       ON T.window_start = S.window_start AND T.status = 'success'
       WHEN NOT MATCHED THEN INSERT
         (run_ts, consumed_checkpoint, window_start, window_end, status,
          sources, totals, report_md)
       VALUES (@run_ts, SAFE_CAST(NULLIF(@consumed_checkpoint, '') AS TIMESTAMP),
               @window_start, @window_end,
               'success', PARSE_JSON(@sources), PARSE_JSON(@totals), @report_md)"

    # Confirm the row is there (completion signal = the artifact, not the exit code).
    bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" --format=csv query \
      --use_legacy_sql=false --quiet \
      --parameter="window_start:TIMESTAMP:$(<"$tmp_dir/window_start")" \
      "SELECT status FROM ${TABLE}
       WHERE window_start = @window_start AND status = 'success'" | tail -1 \
      | grep -q success || { echo "checkin-write: row did not land" >&2; exit 1; }
    echo "checkin-write: success row landed for window starting $(<"$tmp_dir/window_start")"
    ;;

  failed)
    shift
    REASON="unspecified"
    [[ "${1:-}" == "--reason" ]] && REASON="${2:?--reason needs a value}"
    checkpoint="$(resolve_checkpoint)"
    if [[ "$checkpoint" == "none" ]]; then
      # First run ever: anchor the zero-length failed window at now.
      checkpoint="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      ckpt_param=""
    else
      ckpt_param="$checkpoint"
    fi
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query \
      --use_legacy_sql=false --quiet \
      --parameter="run_ts:TIMESTAMP:${now}" \
      --parameter="consumed_checkpoint:STRING:${ckpt_param}" \
      --parameter="window_start:TIMESTAMP:${checkpoint}" \
      --parameter="reason:STRING:${REASON}" \
      "INSERT INTO ${TABLE}
         (run_ts, consumed_checkpoint, window_start, window_end, status, fail_reason)
       VALUES (@run_ts, SAFE_CAST(NULLIF(@consumed_checkpoint, '') AS TIMESTAMP),
               @window_start, @window_start, 'failed', @reason)"
    echo "checkin-write: failed row recorded (${REASON})"
    ;;

  *)
    echo "usage: checkin-write.sh success <payload.json> | failed --reason <text>" >&2
    exit 64
    ;;
esac
