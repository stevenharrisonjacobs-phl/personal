#!/usr/bin/env python3
"""spend_checkin_costs.py — cloud-portable live-cost pulls for the daily spend
check-in: BigQuery scanning (snapfix-agents), LLM run costs via LangSmith, and
Apify actor runs. Each is pulled for the requested window AND the same window
seven days earlier (the week-over-week trend baseline).

This is the Python port of spend-checkin-costs.sh for environments without the
Cloud SDK (`bq`/`gcloud`) or the ~/code/snapfix sibling checkout — the bash
wrapper execs this file when `bq` is absent. The merged-JSON contract is
identical: ONE object on stdout with keys window/bigquery/langsmith/apify/
errors. Per-source failures never kill the run — they land in .errors[]
naming the missing env var/key (fail loudly by name, never a bare
"unavailable").

Credentials come from the environment, not sibling checkouts:
  SNAPFIX_SA_B64       base64 of the snapfix service-account JSON, decoded
                       in-process only (never written to disk, never echoed)
  LANGSMITH_API_KEY    LangSmith run costs (or LANGSMITH_AUTH=proxy)
  APIFY_API_TOKEN      Apify actor runs (or APIFY_AUTH=proxy)

Masked mode: when <SOURCE>_AUTH=proxy, the request is sent WITHOUT a locally
built Authorization header (the platform proxy injects credentials) and the
missing-token guard for that source is suppressed.

Usage: spend_checkin_costs.py --start 2026-09-07T10:00:00Z --end 2026-09-08T10:00:00Z
"""

from __future__ import annotations

import base64
import binascii
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation

from collector_common import _http_get_json, parse_iso

USAGE = "usage: --start <utc-ts> --end <utc-ts>"

BQ_PROJECT = "snapfix-agents"
BQ_LOCATION = "US"
# Kept textually identical to the bash version's bq query (backtick escapes
# aside) so the two paths bill and bucket the same way.
BQ_SQL = """WITH jobs AS (
       SELECT creation_time, total_bytes_processed, referenced_tables
       FROM `region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
       WHERE job_type = 'QUERY' AND error_result IS NULL
         AND creation_time >= TIMESTAMP_SUB(@win_start, INTERVAL 7 DAY)
         AND creation_time < @win_end
     )
     SELECT
       ROUND(SUM(IF(creation_time >= @win_start, total_bytes_processed, 0)) / POW(1024,4) * 6.25, 4) AS cost,
       ROUND(SUM(IF(creation_time < TIMESTAMP_SUB(@win_end, INTERVAL 7 DAY)
                    AND creation_time < @win_start, total_bytes_processed, 0)) / POW(1024,4) * 6.25, 4) AS prev_cost,
       ARRAY(
         SELECT AS STRUCT CONCAT(t.dataset_id, '.', t.table_id) AS name,
                ROUND(SUM(j.total_bytes_processed) / POW(1024,4) * 6.25, 4) AS cost
         FROM jobs j, UNNEST(j.referenced_tables) t
         WHERE j.creation_time >= @win_start
         GROUP BY name ORDER BY cost DESC LIMIT 3
       ) AS top
     FROM jobs"""

# Project names drift (Snapfix-Agents has already been renamed once); a
# missing project is a note, never a dead pull.
# Production snapfix LangSmith projects, DISCOVERED at pull time rather than
# hardcoded. The previous fixed tuple read ("Snapfix", "Snapfix-Agents") — and
# "Snapfix-Agents" matches nothing, because LangSmith project lookup is
# case-sensitive and the real project is "snapfix-agents". That typo hid eight
# projects' LLM spend behind a note nobody reads. A hardcoded list also stops
# covering anything added later, so discovery is the fix, not a corrected list.
LANGSMITH_PROJECT_PREFIX = "snapfix"
# Dev/test projects are real money but not PRODUCTION spend, which is the
# question this report answers.
LANGSMITH_EXCLUDE_MARKERS = ("-dev",)

APIFY_URL = "https://api.apify.com/v2/actor-runs?desc=1&limit=500"
APIFY_ACTS_URL = "https://api.apify.com/v2/acts"


class UsageError(Exception):
    """Bad argv — exits 64, matching the bash wrapper."""


# ---- pure helpers -----------------------------------------------------------

def prev_window(start: datetime, end: datetime) -> tuple[datetime, datetime]:
    return start - timedelta(days=7), end - timedelta(days=7)


def parse_args(argv):
    start = end = ""
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg == "--start" and args:
            start = args.pop(0)
        elif arg == "--end" and args:
            end = args.pop(0)
        elif arg in ("--start", "--end"):
            raise UsageError(USAGE)
        else:
            raise UsageError(f"unknown arg: {arg}")
    if not (start and end):
        raise UsageError(USAGE)
    return start, end


def decode_sa(sa_b64: str) -> dict:
    """base64 → service-account dict, in memory only. Raises ValueError on any
    malformed input; callers must never surface the value itself."""
    try:
        info = json.loads(base64.b64decode(sa_b64, validate=True))
    except (binascii.Error, ValueError) as exc:
        raise ValueError("not base64-encoded JSON") from exc
    if not isinstance(info, dict):
        raise ValueError("decoded JSON is not an object")
    return info


# ---- BigQuery scanning (snapfix-agents), both windows in one query ----------

def _make_bq_runner(info):
    # Lazy imports: only the BigQuery path needs google-cloud-bigquery.
    from google.cloud import bigquery
    from google.oauth2 import service_account

    creds = service_account.Credentials.from_service_account_info(
        info, scopes=["https://www.googleapis.com/auth/cloud-platform"])
    client = bigquery.Client(project=BQ_PROJECT, credentials=creds,
                             location=BQ_LOCATION)

    def run_query(sql, start, end):
        job = client.query(sql, job_config=bigquery.QueryJobConfig(
            query_parameters=[
                bigquery.ScalarQueryParameter("win_start", "TIMESTAMP", start),
                bigquery.ScalarQueryParameter("win_end", "TIMESTAMP", end),
            ]))
        row = dict(list(job.result())[0])
        row["top"] = [dict(t) for t in row.get("top") or []]
        return row

    return run_query


def pull_bigquery(start, end, env, run_query=None):
    sa_b64 = env.get("SNAPFIX_SA_B64")
    if not sa_b64:
        return None, ["SNAPFIX_SA_B64 missing from env — BigQuery pull skipped"]
    try:
        info = decode_sa(sa_b64)
    except ValueError:
        # Deliberately does NOT echo the value or the decode detail.
        return None, ["SNAPFIX_SA_B64 could not be decoded as service-account"
                      " JSON — BigQuery pull skipped"]
    try:
        if run_query is None:
            run_query = _make_bq_runner(info)
        return run_query(BQ_SQL, start, end), []
    except Exception as exc:  # noqa: BLE001 — degrade, never die
        return None, [f"bigquery pull failed: {type(exc).__name__}: {exc}"]


# ---- LangSmith run costs, both windows in one pull --------------------------

def production_projects(client):
    """Every snapfix* project except dev ones, from the live project list.

    Case-insensitive on purpose: the projects are spelled inconsistently
    ("Snapfix" beside "snapfix-agents") and matching the spelling by hand is
    what broke before.
    """
    names = [getattr(p, "name", None) or "" for p in client.list_projects()]
    return sorted(
        n for n in names
        if n.lower().startswith(LANGSMITH_PROJECT_PREFIX)
        and not any(m in n.lower() for m in LANGSMITH_EXCLUDE_MARKERS)
    )


def langsmith_costs(client, start, end):
    prev_start, prev_end = prev_window(start, end)
    cur_total, prev_total = Decimal("0"), Decimal("0")
    top, notes = [], []
    try:
        projects = production_projects(client)
    except Exception as exc:  # noqa: BLE001 — degrade with a note, never die
        return {"cost": 0.0, "prev_cost": 0.0, "top": [],
                "notes": [f"project discovery failed: {type(exc).__name__}"]}
    if not projects:
        notes.append(f"no {LANGSMITH_PROJECT_PREFIX}* production projects found")
    for project in projects:
        try:
            runs = list(client.list_runs(project_name=project,
                                         start_time=prev_start,
                                         end_time=end, is_root=True))
        except Exception as exc:  # noqa: BLE001 — a rename is a note
            notes.append(f"project {project}: {type(exc).__name__}")
            continue
        for r in runs:
            try:
                cost = Decimal(str(r.total_cost)) if r.total_cost is not None else Decimal("0")
            except (InvalidOperation, ValueError):
                cost = Decimal("0")
            t = (r.start_time.replace(tzinfo=timezone.utc)
                 if r.start_time.tzinfo is None else r.start_time)
            if start <= t < end:
                cur_total += cost
                top.append({"name": r.name or "?", "cost": float(cost)})
            elif prev_start <= t < prev_end:
                prev_total += cost
    top = sorted(top, key=lambda x: -x["cost"])[:3]
    return {"cost": round(float(cur_total), 4),
            "prev_cost": round(float(prev_total), 4),
            "top": top, "notes": notes}


def pull_langsmith(start, end, env, client_factory=None):
    api_key = env.get("LANGSMITH_API_KEY")
    proxied = env.get("LANGSMITH_AUTH") == "proxy"
    if not api_key and not proxied:
        return None, ["LANGSMITH_API_KEY missing from env — LangSmith pull skipped"]
    if client_factory is None:
        def client_factory():
            from langsmith import Client  # lazy: pip package, cloud-only path
            return Client() if proxied else Client(api_key=api_key)
    try:
        client = client_factory()
        return langsmith_costs(client, parse_iso(start), parse_iso(end)), []
    except Exception as exc:  # noqa: BLE001 — degrade, never die
        return None, [f"langsmith pull failed: {type(exc).__name__}: {exc}"]


# ---- Apify actor runs, both windows from one page ---------------------------

def actor_names(act_ids, http_get, headers):
    """Resolve actor ids to readable names, best effort.

    A run object carries no name, only an opaque id, and "WI0tj4Ieb5Kq458gB
    $0.72" tells a morning reader nothing. One extra GET per DISTINCT actor in
    the top-3 — never per run. Any failure leaves that actor as its id rather
    than failing the pull.
    """
    names = {}
    for act_id in act_ids:
        try:
            data = http_get(f"{APIFY_ACTS_URL}/{act_id}", headers) or {}
            names[act_id] = (data.get("data") or {}).get("name") or act_id
        except Exception:  # noqa: BLE001 — a name is a nicety, never a failure
            names[act_id] = act_id
    return names


def bucket_apify(items, start, end, http_get=None, headers=None):
    prev_start, prev_end = prev_window(start, end)
    cur, prev = 0.0, 0.0
    actors = defaultdict(float)
    for r in items:
        started = r.get("startedAt")
        if not started:
            continue
        t = parse_iso(started)
        cost = r.get("usageTotalUsd") or 0
        if start <= t < end:
            cur += cost
            # The API field is actId. It was read as actorId, which does not
            # exist on the run object, so every actor bucketed under "?" and
            # the top-drivers line named nothing. actorId stays as a fallback
            # in case the field is ever spelled that way.
            actors[r.get("actId") or r.get("actorId") or "?"] += cost
        elif prev_start <= t < prev_end:
            prev += cost
    ranked = sorted(actors.items(), key=lambda x: -x[1])[:3]
    names = ({} if http_get is None
             else actor_names([a for a, _ in ranked if a != "?"], http_get, headers or {}))
    top = [{"name": names.get(a, a), "cost": round(c, 4)} for a, c in ranked]
    return {"cost": round(cur, 4), "prev_cost": round(prev, 4), "top": top}


def pull_apify(start, end, env, http_get=None):
    token = env.get("APIFY_API_TOKEN")
    proxied = env.get("APIFY_AUTH") == "proxy"
    if not token and not proxied:
        return None, ["APIFY_API_TOKEN missing from env — Apify pull skipped"]
    headers = {} if proxied else {"Authorization": f"Bearer {token}"}
    if http_get is None:
        http_get = _http_get_json
    try:
        raw = http_get(APIFY_URL, headers)
        items = raw["data"]["items"]
        return bucket_apify(items, parse_iso(start), parse_iso(end),
                            http_get=http_get, headers=headers), []
    except Exception as exc:  # noqa: BLE001 — degrade, never die
        return None, [f"apify pull failed: {type(exc).__name__}: {exc}"]


# ---- merge ------------------------------------------------------------------

def collect(start, end, env, *, bq_run_query=None, langsmith_client_factory=None,
            apify_http_get=None):
    errors = []
    bigquery, errs = pull_bigquery(start, end, env, run_query=bq_run_query)
    errors += errs
    langsmith, errs = pull_langsmith(start, end, env,
                                     client_factory=langsmith_client_factory)
    errors += errs
    apify, errs = pull_apify(start, end, env, http_get=apify_http_get)
    errors += errs
    return {
        "window": {"start": start, "end": end},
        "bigquery": bigquery,
        "langsmith": langsmith,
        "apify": apify,
        "errors": errors,
    }


def main(argv=None, env=None):
    if argv is None:
        argv = sys.argv[1:]
    if env is None:
        env = os.environ
    try:
        start, end = parse_args(argv)
    except UsageError as exc:
        print(exc, file=sys.stderr)
        return 64
    print(json.dumps(collect(start, end, env), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
