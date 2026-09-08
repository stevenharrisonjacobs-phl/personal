#!/usr/bin/env bash
# spend-checkin-costs.sh — deterministic live-cost pulls for the daily spend
# check-in: BigQuery scanning (snapfix-agents), LLM run costs via LangSmith,
# and Apify actor runs. Each is pulled for the requested window AND the same
# window seven days earlier (the week-over-week trend baseline, R3).
#
# Emits ONE JSON object on stdout. Per-source failures never kill the script —
# they land in .errors[] naming the missing env/key/path (KTD6: fail loudly by
# name, never a bare "unavailable"). Row-level pull detail belongs in
# .context/, where the caller redirects this output.
#
# Adapted from the /snapfix-costs recipes. Secrets come from the snapfix
# checkout (cross-repo coupling recorded in the plan):
#   ~/code/snapfix/.env.local            LANGSMITH_API_KEY, APIFY_API_TOKEN
#   ~/code/snapfix/.gcp/snapfix-track.json   BQ scan pull (snapfix-agents)
#   ~/code/snapfix-langgraph             uv env with the langsmith package
#
# Usage: spend-checkin-costs.sh --start 2026-09-07T10:00:00Z --end 2026-09-08T10:00:00Z
set -uo pipefail

START="" END=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --start) START="$2"; shift 2 ;;
    --end)   END="$2";   shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done
[[ -n "$START" && -n "$END" ]] || { echo "usage: --start <utc-ts> --end <utc-ts>" >&2; exit 64; }

SNAPFIX_ENV="$HOME/code/snapfix/.env.local"
SNAPFIX_SA="$HOME/code/snapfix/.gcp/snapfix-track.json"
LANGGRAPH_DIR="$HOME/code/snapfix-langgraph"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
: > "$tmp_dir/errors"

if [[ -f "$SNAPFIX_ENV" ]]; then
  set -a; # shellcheck disable=SC1090
  source "$SNAPFIX_ENV"; set +a
else
  echo "snapfix env missing at $SNAPFIX_ENV — LangSmith and Apify pulls skipped" >> "$tmp_dir/errors"
fi

# ---- BigQuery scanning (snapfix-agents), both windows in one query ----------
# bq resolves credentials through gcloud, and the ambient user credential can
# be reauth-expired under launchd (the measured nightly failure). Activate the
# snapfix SA into a THROWAWAY gcloud config so this never depends on — or
# rewrites — Steven's real gcloud account (same pattern as nightly-sync.sh).
if [[ -f "$SNAPFIX_SA" ]]; then
  export CLOUDSDK_CONFIG="$tmp_dir/gcloud"
  gcloud auth activate-service-account --key-file="$SNAPFIX_SA" >/dev/null 2>&1 \
    || echo "snapfix SA activation failed from $SNAPFIX_SA" >> "$tmp_dir/errors"
  GOOGLE_APPLICATION_CREDENTIALS="$SNAPFIX_SA" \
  bq --project_id=snapfix-agents --location=US --format=json query \
    --use_legacy_sql=false --quiet \
    --parameter="win_start:TIMESTAMP:${START}" \
    --parameter="win_end:TIMESTAMP:${END}" \
    "WITH jobs AS (
       SELECT creation_time, total_bytes_processed, referenced_tables
       FROM \`region-us\`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
       WHERE job_type = 'QUERY' AND error_result IS NULL
         AND creation_time >= TIMESTAMP_SUB(@win_start, INTERVAL 7 DAY)
         AND creation_time < @win_end
     )
     SELECT
       ROUND(SUM(IF(creation_time >= @win_start, total_bytes_processed, 0)) / POW(1024,4) * 6.25, 4) AS cost,
       ROUND(SUM(IF(creation_time <  TIMESTAMP_SUB(@win_end, INTERVAL 7 DAY), total_bytes_processed, 0)) / POW(1024,4) * 6.25, 4) AS prev_cost,
       ARRAY(
         SELECT AS STRUCT CONCAT(t.dataset_id, '.', t.table_id) AS name,
                ROUND(SUM(j.total_bytes_processed) / POW(1024,4) * 6.25, 4) AS cost
         FROM jobs j, UNNEST(j.referenced_tables) t
         WHERE j.creation_time >= @win_start
         GROUP BY name ORDER BY cost DESC LIMIT 3
       ) AS top
     FROM jobs" > "$tmp_dir/bigquery.json" 2>"$tmp_dir/bq.err" \
  || { echo "bigquery pull failed: $(tail -1 "$tmp_dir/bq.err" 2>/dev/null)" >> "$tmp_dir/errors"; rm -f "$tmp_dir/bigquery.json"; }
  unset CLOUDSDK_CONFIG
else
  echo "snapfix SA key missing at $SNAPFIX_SA — BigQuery pull skipped" >> "$tmp_dir/errors"
fi

# ---- LangSmith run costs, both windows in one pull --------------------------
if [[ -n "${LANGSMITH_API_KEY:-}" && -d "$LANGGRAPH_DIR" ]]; then
  ( cd "$LANGGRAPH_DIR" && \
    LANGSMITH_API_KEY="$LANGSMITH_API_KEY" WIN_START="$START" WIN_END="$END" \
    uv run python - <<'PYEOF' > "$tmp_dir/langsmith.json" 2>"$tmp_dir/ls.err"
import json, os
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from langsmith import Client

start = datetime.fromisoformat(os.environ["WIN_START"].replace("Z", "+00:00"))
end = datetime.fromisoformat(os.environ["WIN_END"].replace("Z", "+00:00"))
prev_start, prev_end = start - timedelta(days=7), end - timedelta(days=7)

client = Client(api_key=os.environ["LANGSMITH_API_KEY"])
cur_total, prev_total = Decimal("0"), Decimal("0")
top, notes = [], []
# Project names drift (Snapfix-Agents has already been renamed once); a
# missing project is a note, never a dead pull.
for project in ("Snapfix", "Snapfix-Agents"):
    try:
        runs = list(client.list_runs(project_name=project, start_time=prev_start, is_root=True))
    except Exception as exc:
        notes.append(f"project {project}: {type(exc).__name__}")
        continue
    for r in runs:
        cost = r.total_cost or Decimal("0")
        t = r.start_time.replace(tzinfo=timezone.utc) if r.start_time.tzinfo is None else r.start_time
        if start <= t < end:
            cur_total += cost
            top.append({"name": r.name or "?", "cost": float(cost)})
        elif prev_start <= t < prev_end:
            prev_total += cost
top = sorted(top, key=lambda x: -x["cost"])[:3]
print(json.dumps({"cost": round(float(cur_total), 4),
                  "prev_cost": round(float(prev_total), 4), "top": top,
                  "notes": notes}))
PYEOF
  ) || { echo "langsmith pull failed: $(tail -1 "$tmp_dir/ls.err" 2>/dev/null)" >> "$tmp_dir/errors"; rm -f "$tmp_dir/langsmith.json"; }
else
  [[ -z "${LANGSMITH_API_KEY:-}" ]] && echo "LANGSMITH_API_KEY missing from $SNAPFIX_ENV — LangSmith pull skipped" >> "$tmp_dir/errors"
  [[ ! -d "$LANGGRAPH_DIR" ]] && echo "langgraph dir missing at $LANGGRAPH_DIR — LangSmith pull skipped" >> "$tmp_dir/errors"
fi

# ---- Apify actor runs, both windows from one page ---------------------------
if [[ -n "${APIFY_API_TOKEN:-}" ]]; then
  curl -sf "https://api.apify.com/v2/actor-runs?desc=1&limit=500" \
    -H "Authorization: Bearer $APIFY_API_TOKEN" > "$tmp_dir/apify_raw.json" \
  && WIN_START="$START" WIN_END="$END" python3 - "$tmp_dir/apify_raw.json" <<'PYEOF' > "$tmp_dir/apify.json" 2>"$tmp_dir/apify.err"
import json, os, sys
from collections import defaultdict
from datetime import datetime, timedelta

start = datetime.fromisoformat(os.environ["WIN_START"].replace("Z", "+00:00"))
end = datetime.fromisoformat(os.environ["WIN_END"].replace("Z", "+00:00"))
prev_start, prev_end = start - timedelta(days=7), end - timedelta(days=7)

runs = json.load(open(sys.argv[1]))["data"]["items"]
cur, prev = 0.0, 0.0
actors = defaultdict(float)
for r in runs:
    started = r.get("startedAt")
    if not started:
        continue
    t = datetime.fromisoformat(started.replace("Z", "+00:00"))
    cost = r.get("usageTotalUsd") or 0
    if start <= t < end:
        cur += cost
        actors[r.get("actorId") or "?"] += cost
    elif prev_start <= t < prev_end:
        prev += cost
top = [{"name": a, "cost": round(c, 4)}
       for a, c in sorted(actors.items(), key=lambda x: -x[1])[:3]]
print(json.dumps({"cost": round(cur, 4), "prev_cost": round(prev, 4), "top": top}))
PYEOF
  [[ -s "$tmp_dir/apify.json" ]] || { echo "apify pull failed: $(tail -1 "$tmp_dir/apify.err" 2>/dev/null)" >> "$tmp_dir/errors"; rm -f "$tmp_dir/apify.json"; }
else
  echo "APIFY_API_TOKEN missing from $SNAPFIX_ENV — Apify pull skipped" >> "$tmp_dir/errors"
fi

# ---- Merge ------------------------------------------------------------------
WIN_START="$START" WIN_END="$END" python3 - "$tmp_dir" <<'PYEOF'
import json, os, sys
tmp = sys.argv[1]

def load(name):
    path = f"{tmp}/{name}.json"
    if not os.path.exists(path):
        return None
    with open(path) as f:
        data = json.load(f)
    # bq --format=json returns a one-row array; collectors print bare objects.
    return data[0] if isinstance(data, list) else data

errors = [line for line in open(f"{tmp}/errors").read().splitlines() if line]
print(json.dumps({
    "window": {"start": os.environ["WIN_START"], "end": os.environ["WIN_END"]},
    "bigquery": load("bigquery"),
    "langsmith": load("langsmith"),
    "apify": load("apify"),
    "errors": errors,
}, indent=1))
PYEOF
