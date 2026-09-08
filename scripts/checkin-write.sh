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
#       Wrapper-owned failure recording (R11): needs NO composed artifacts.
#       Resolves the checkpoint itself and writes a minimal status='failed'
#       row whose window is zero-length, so it can never advance anything.
#
# Integrity contract (KTD8):
#   * MERGE matches ONLY status='success' rows for the same window_start, so
#     a double fire (calendar + wake, manual + scheduled) lands zero or one
#     success row — and a failed row never blocks a later success.
#   * The checkpoint is re-resolved immediately before the write; if it moved
#     since the payload was composed, the write aborts loudly.
#   * Append-only: no UPDATE path exists here. Recovery is BQ time travel.
#   * Content checks (R14): report_md under the length cap, and no
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

    # Validate shape, windows, content rules, and recompute totals. Writes one
    # file per bq parameter into $tmp_dir so values with newlines stay intact.
    python3 - "$PAYLOAD" "$tmp_dir" <<'PYEOF'
import json, re, sys
payload_path, out_dir = sys.argv[1], sys.argv[2]
p = json.load(open(payload_path))

errors = []
for field in ("run_ts", "window_start", "window_end", "sources", "totals", "report_md"):
    if field not in p:
        errors.append(f"missing field: {field}")
if errors:
    sys.exit("checkin-write: invalid payload: " + "; ".join(errors))

ts = re.compile(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|\+00:?00)$")
for field in ("run_ts", "window_start", "window_end"):
    if not ts.match(str(p[field])):
        errors.append(f"{field} is not a UTC timestamp: {p[field]}")
if p.get("consumed_checkpoint") and not ts.match(str(p["consumed_checkpoint"])):
    errors.append("consumed_checkpoint is not a UTC timestamp")
if str(p["window_end"]) <= str(p["window_start"]):
    errors.append("window_end must be after window_start")
if str(p["run_ts"]) < str(p["window_end"]):
    errors.append("run_ts must be at or after window_end")

md = p["report_md"]
if len(md) > 100_000:
    errors.append(f"report_md over length cap: {len(md)} > 100000")
digit_runs = re.findall(r"\d{9,}", md)
if digit_runs:
    errors.append(f"report_md contains account-number-like digit runs: {digit_runs[:3]}")

# Headline totals must equal the per-source totals they claim to summarize.
mapping = {"personal_cash": "mirror", "mercury_cash": "mercury",
           "cloud_billed": "vantage", "cloud_live": "live_costs"}
for headline, source in mapping.items():
    h = p["totals"].get(headline)
    s = (p["sources"].get(source) or {}).get("total")
    if h is None and s is None:
        continue
    if (h is None) != (s is None):
        errors.append(f"totals.{headline} and sources.{source}.total disagree on presence")
    elif abs(float(h) - float(s)) > 0.01:
        errors.append(f"totals.{headline}={h} != sources.{source}.total={s}")

if errors:
    sys.exit("checkin-write: refused: " + "; ".join(errors))

out = {
    "run_ts": str(p["run_ts"]),
    "consumed_checkpoint": str(p.get("consumed_checkpoint") or "none"),
    "window_start": str(p["window_start"]),
    "window_end": str(p["window_end"]),
    "sources": json.dumps(p["sources"]),
    "totals": json.dumps(p["totals"]),
    "report_md": md,
}
for name, value in out.items():
    with open(f"{out_dir}/{name}", "w") as f:
        f.write(value)
PYEOF

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

    # Confirm the row is there (completion signal = the artifact, KTD7).
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
