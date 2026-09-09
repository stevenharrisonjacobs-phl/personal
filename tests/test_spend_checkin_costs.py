"""Offline tests for the cloud-portable spend-cost collector and Mercury pull.

No GCP, no network — every HTTP/BQ/LangSmith touchpoint is injected. The
collector's merged-JSON schema (window/bigquery/langsmith/apify/errors) is the
contract the check-in validator and report generator consume, so its shape and
its degraded-source behavior (source null + named errors[] entry, never a dead
run) are pinned here. Run: .venv/bin/python -m pytest tests/ -q
"""

from __future__ import annotations

import base64
import json
import os
import stat
import subprocess
import sys
import urllib.error
from datetime import datetime, timezone
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

import mercury_pull  # noqa: E402
import spend_checkin_costs as scc  # noqa: E402

START = "2026-09-07T10:00:00Z"
END = "2026-09-08T10:00:00Z"

SA_B64 = base64.b64encode(
    json.dumps({"type": "service_account", "project_id": "snapfix-agents"}).encode()
).decode()


def base_env(**overrides):
    env = {
        "SNAPFIX_SA_B64": SA_B64,
        "LANGSMITH_API_KEY": "ls-test-key",
        "APIFY_API_TOKEN": "ap-test-token",
    }
    env.update(overrides)
    return {k: v for k, v in env.items() if v is not None}


# -- fixture fakes ------------------------------------------------------------

BQ_ROW = {"cost": 1.23, "prev_cost": 0.5, "top": [{"name": "ds.tbl", "cost": 1.0}]}


def make_fake_bq(calls=None):
    def run_query(sql, start, end):
        if calls is not None:
            calls.append({"sql": sql, "start": start, "end": end})
        return dict(BQ_ROW)
    return run_query


class FakeRun:
    def __init__(self, name, total_cost, start_time):
        self.name = name
        self.total_cost = total_cost
        self.start_time = start_time


class FakeLangsmithClient:
    """list_runs keyed by project; unknown project raises (the rename case)."""

    def __init__(self, runs_by_project):
        self.runs_by_project = runs_by_project
        self.calls = []

    def list_runs(self, *, project_name, start_time, end_time, is_root):
        self.calls.append({"project_name": project_name, "start_time": start_time,
                           "end_time": end_time, "is_root": is_root})
        if project_name not in self.runs_by_project:
            raise LookupError(f"project not found: {project_name}")
        return iter(self.runs_by_project[project_name])


def ts(iso):
    return datetime.fromisoformat(iso.replace("Z", "+00:00"))


def apify_payload(items):
    return {"data": {"items": items}}


def make_http_get(responses, calls=None):
    """responses: callable(url) -> parsed json, or a dict to return always."""
    def http_get(url, headers):
        if calls is not None:
            calls.append({"url": url, "headers": dict(headers)})
        return responses(url) if callable(responses) else responses
    return http_get


APIFY_ITEMS = [
    {"actorId": "actorA", "startedAt": "2026-09-07T12:00:00Z", "usageTotalUsd": 2.0},
    {"actorId": "actorA", "startedAt": "2026-09-07T13:00:00Z", "usageTotalUsd": 1.0},
    {"actorId": "actorB", "startedAt": "2026-09-08T01:00:00Z", "usageTotalUsd": 0.25},
    # prev window (7 days earlier)
    {"actorId": "actorA", "startedAt": "2026-08-31T12:00:00Z", "usageTotalUsd": 4.0},
    # outside both windows
    {"actorId": "actorC", "startedAt": "2026-08-20T12:00:00Z", "usageTotalUsd": 9.0},
    # missing startedAt is skipped
    {"actorId": "actorD", "usageTotalUsd": 5.0},
]

LS_RUNS = {
    "Snapfix": [
        FakeRun("chain-a", 0.5, ts("2026-09-07T11:00:00Z")),
        FakeRun("chain-b", 0.25, ts("2026-08-31T11:00:00Z")),  # prev window
    ],
    "Snapfix-Agents": [
        FakeRun("agent-x", 1.5, ts("2026-09-07T15:00:00Z")),
        FakeRun("agent-naive", 0.125, datetime(2026, 9, 7, 16, 0, 0)),  # naive → UTC
        FakeRun(None, None, ts("2026-09-08T02:00:00Z")),  # no name, no cost
    ],
}


def collect_with(env, *, bq=None, ls_factory=None, apify_get=None):
    if bq is None:
        bq = make_fake_bq()
    if ls_factory is None:
        ls_factory = lambda: FakeLangsmithClient(LS_RUNS)  # noqa: E731
    if apify_get is None:
        apify_get = make_http_get(apify_payload(APIFY_ITEMS))
    return scc.collect(START, END, env, bq_run_query=bq,
                       langsmith_client_factory=ls_factory, apify_http_get=apify_get)


# -- collector: happy path, schema, bucketing ---------------------------------

def test_collect_happy_matches_bash_schema():
    result = collect_with(base_env())
    assert set(result) == {"window", "bigquery", "langsmith", "apify", "errors"}
    assert result["window"] == {"start": START, "end": END}
    assert result["errors"] == []
    assert result["bigquery"] == BQ_ROW
    for source in ("bigquery", "langsmith", "apify"):
        for key in ("cost", "prev_cost", "top"):
            assert key in result[source], f"{source} missing {key}"
        for entry in result[source]["top"]:
            assert set(entry) == {"name", "cost"}
    assert "notes" in result["langsmith"]


def test_bq_query_text_and_params_preserved():
    calls = []
    collect_with(base_env(), bq=make_fake_bq(calls))
    assert len(calls) == 1
    sql = calls[0]["sql"]
    assert "`region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT" in sql
    assert "@win_start" in sql and "@win_end" in sql
    assert "TIMESTAMP_SUB(@win_start, INTERVAL 7 DAY)" in sql
    assert "POW(1024,4) * 6.25" in sql
    assert calls[0]["start"] == START and calls[0]["end"] == END


def test_langsmith_bucketing_windows_and_top():
    client = FakeLangsmithClient(LS_RUNS)
    result = collect_with(base_env(), ls_factory=lambda: client)["langsmith"]
    # window runs: 0.5 + 1.5 + 0.125 (naive treated as UTC) + 0 (None cost)
    assert result["cost"] == 2.125
    assert result["prev_cost"] == 0.25
    assert [t["name"] for t in result["top"]] == ["agent-x", "chain-a", "agent-naive"]
    assert result["notes"] == []
    # both projects pulled over prev_start..end, root runs only
    assert [c["project_name"] for c in client.calls] == ["Snapfix", "Snapfix-Agents"]
    for c in client.calls:
        assert c["is_root"] is True
        assert c["start_time"] == ts("2026-08-31T10:00:00Z")
        assert c["end_time"] == ts(END)


def test_langsmith_missing_project_is_note_not_error():
    factory = lambda: FakeLangsmithClient({"Snapfix": LS_RUNS["Snapfix"]})  # noqa: E731
    result = collect_with(base_env(), ls_factory=factory)
    assert result["errors"] == []
    assert result["langsmith"]["notes"] == ["project Snapfix-Agents: LookupError"]
    assert result["langsmith"]["cost"] == 0.5


def test_apify_bucketing_windows_and_top():
    result = collect_with(base_env())["apify"]
    assert result["cost"] == 3.25          # 2.0 + 1.0 + 0.25 in window
    assert result["prev_cost"] == 4.0      # the 2026-08-31 run
    assert result["top"] == [{"name": "actorA", "cost": 3.0},
                             {"name": "actorB", "cost": 0.25}]


# -- collector: masked mode (proxy auth) --------------------------------------

def test_apify_env_mode_sends_bearer_header():
    calls = []
    collect_with(base_env(), apify_get=make_http_get(apify_payload([]), calls))
    assert calls[0]["headers"].get("Authorization") == "Bearer ap-test-token"


def test_apify_masked_mode_no_local_auth_header_and_guard_suppressed():
    calls = []
    env = base_env(APIFY_API_TOKEN=None, APIFY_AUTH="proxy")
    result = collect_with(env, apify_get=make_http_get(apify_payload(APIFY_ITEMS), calls))
    assert "Authorization" not in calls[0]["headers"]
    assert result["apify"] is not None
    assert not any("APIFY_API_TOKEN" in e for e in result["errors"])


def test_langsmith_masked_mode_guard_suppressed():
    env = base_env(LANGSMITH_API_KEY=None, LANGSMITH_AUTH="proxy")
    result = collect_with(env)
    assert result["langsmith"] is not None
    assert not any("LANGSMITH_API_KEY" in e for e in result["errors"])


# -- collector: named degradation, never a dead run ---------------------------

def test_missing_apify_token_named_while_other_sources_emit():
    result = collect_with(base_env(APIFY_API_TOKEN=None))
    assert result["apify"] is None
    assert any("APIFY_API_TOKEN" in e for e in result["errors"])
    assert result["bigquery"] is not None
    assert result["langsmith"] is not None


def test_missing_sa_b64_named_while_other_sources_emit():
    result = collect_with(base_env(SNAPFIX_SA_B64=None))
    assert result["bigquery"] is None
    assert any("SNAPFIX_SA_B64" in e for e in result["errors"])
    assert result["langsmith"] is not None
    assert result["apify"] is not None


def test_undecodable_sa_b64_named_without_echoing_value():
    secret = "!!not//valid==b64"
    result = collect_with(base_env(SNAPFIX_SA_B64=secret))
    assert result["bigquery"] is None
    assert any("SNAPFIX_SA_B64" in e for e in result["errors"])
    assert all(secret not in e for e in result["errors"])


def test_langsmith_failure_degrades_to_null_plus_error():
    def boom():
        raise RuntimeError("connection refused")
    result = collect_with(base_env(), ls_factory=boom)
    assert result["langsmith"] is None
    assert any(e.startswith("langsmith pull failed:") for e in result["errors"])
    assert result["bigquery"] is not None
    assert result["apify"] is not None
    # degraded shape: schema keys all still present for the validator
    assert set(result) == {"window", "bigquery", "langsmith", "apify", "errors"}


def test_apify_http_failure_degrades_to_null_plus_error():
    def boom(url, headers):
        raise urllib.error.URLError("timed out")
    result = collect_with(base_env(), apify_get=boom)
    assert result["apify"] is None
    assert any(e.startswith("apify pull failed:") for e in result["errors"])


# -- collector: arg contract --------------------------------------------------

def test_parse_args_happy():
    assert scc.parse_args(["--start", START, "--end", END]) == (START, END)


def test_parse_args_missing_and_unknown_exit_64(capsys):
    assert scc.main(["--start", START]) == 64
    assert "usage:" in capsys.readouterr().err
    assert scc.main(["--bogus", "x"]) == 64
    assert "unknown arg: --bogus" in capsys.readouterr().err


# -- window math (shared): month-boundary prev window -------------------------

def test_prev_window_spans_month_boundary():
    start, end = ts("2026-09-03T00:00:00Z"), ts("2026-09-04T00:00:00Z")
    prev_start, prev_end = scc.prev_window(start, end)
    assert prev_start == ts("2026-08-27T00:00:00Z")
    assert prev_end == ts("2026-08-28T00:00:00Z")


def test_mercury_window_params_month_boundary():
    params = mercury_pull.window_params("2026-09-03T00:00:00Z", "2026-09-04T00:00:00Z")
    assert params["window"] == ("2026-09-03", "2026-09-04")
    assert params["prev"] == ("2026-08-27", "2026-08-28")


# -- mercury_pull: request construction and outputs ---------------------------

ACCOUNTS = {"accounts": [{"id": "acct-1", "name": "Checking"},
                         {"id": "acct-2", "name": "Savings"}]}


def mercury_responses(url):
    if url.endswith("/accounts"):
        return ACCOUNTS
    return {"total": 1, "transactions": [{"id": "txn-for " + url.split("/account/")[1].split("/")[0]}]}


def run_mercury(tmp_path, env, http_get):
    argv = ["--start", START, "--end", END, "--out", str(tmp_path / "out")]
    return mercury_pull.run(argv, env, http_get)


def test_mercury_request_construction_and_files(tmp_path):
    calls = []
    env = {"MERCURY_API_TOKEN": "mc-test-token"}
    code = run_mercury(tmp_path, env, make_http_get(mercury_responses, calls))
    assert code == 0

    assert calls[0]["url"] == "https://api.mercury.com/api/v1/accounts"
    tx_calls = calls[1:]
    assert len(tx_calls) == 4  # 2 accounts x 2 windows
    for c in calls:
        assert c["headers"].get("Authorization") == "Bearer mc-test-token"

    windows_seen = set()
    for c in tx_calls:
        parsed = urlparse(c["url"])
        assert parsed.path.startswith("/api/v1/account/")
        assert parsed.path.endswith("/transactions")
        q = parse_qs(parsed.query)
        windows_seen.add((q["start"][0], q["end"][0]))
        assert q["limit"] == ["500"] and q["offset"] == ["0"]
    assert windows_seen == {("2026-09-07", "2026-09-08"),   # requested window
                            ("2026-08-31", "2026-09-01")}   # week-prior baseline

    out = tmp_path / "out"
    assert json.loads((out / "accounts.json").read_text()) == ACCOUNTS
    window = json.loads((out / "transactions-window.json").read_text())
    prev = json.loads((out / "transactions-prev.json").read_text())
    assert set(window["accounts"]) == {"acct-1", "acct-2"}
    assert window["window"]["start"] == START and window["window"]["end"] == END
    assert window["window"]["posted_start"] == "2026-09-07"
    assert prev["window"]["posted_start"] == "2026-08-31"
    assert prev["window"]["posted_end"] == "2026-09-01"


def test_mercury_masked_mode_no_local_auth_header(tmp_path):
    calls = []
    env = {"MERCURY_AUTH": "proxy"}  # no MERCURY_API_TOKEN, guard suppressed
    code = run_mercury(tmp_path, env, make_http_get(mercury_responses, calls))
    assert code == 0
    for c in calls:
        assert "Authorization" not in c["headers"]


def test_mercury_missing_token_env_mode_exits_naming_var(tmp_path, capsys):
    calls = []
    code = run_mercury(tmp_path, {}, make_http_get(mercury_responses, calls))
    assert code != 0
    err = capsys.readouterr().err
    assert "MERCURY_API_TOKEN" in err
    assert calls == []                       # never touched the network
    assert not (tmp_path / "out").exists()   # nothing written


def test_mercury_401_exits_naming_auth_no_partial_files(tmp_path, capsys):
    def http_get(url, headers):
        if url.endswith("/accounts"):
            return ACCOUNTS
        raise urllib.error.HTTPError(url, 401, "Unauthorized", None, None)
    code = run_mercury(tmp_path, {"MERCURY_API_TOKEN": "mc-test-token"}, http_get)
    assert code != 0
    err = capsys.readouterr().err
    assert "401" in err
    assert err.count("\n") == 1              # one-line stderr
    assert not (tmp_path / "out").exists()   # no partial output left behind


def test_mercury_network_error_named(tmp_path, capsys):
    def http_get(url, headers):
        raise urllib.error.URLError("connection reset")
    code = run_mercury(tmp_path, {"MERCURY_API_TOKEN": "mc-test-token"}, http_get)
    assert code != 0
    assert "network" in capsys.readouterr().err


def test_mercury_pagination_defensive(tmp_path):
    pages = {"0": [{"id": "t1"}, {"id": "t2"}], "2": [{"id": "t3"}]}

    def http_get(url, headers):
        if url.endswith("/accounts"):
            return {"accounts": [{"id": "acct-1"}]}
        offset = parse_qs(urlparse(url).query)["offset"][0]
        return {"total": 3, "transactions": pages.get(offset, [])}

    code = run_mercury(tmp_path, {"MERCURY_API_TOKEN": "mc-test-token"}, http_get)
    assert code == 0
    window = json.loads((tmp_path / "out" / "transactions-window.json").read_text())
    assert [t["id"] for t in window["accounts"]["acct-1"]] == ["t1", "t2", "t3"]


def test_mercury_missing_start_end_exits_64(tmp_path, capsys):
    assert mercury_pull.run(["--start", START], {}, make_http_get(ACCOUNTS)) == 64
    assert "usage:" in capsys.readouterr().err


# -- dispatch: spend-checkin-costs.sh execs the python port when bq is absent --
# Chosen approach: real subprocess with a PATH that carries python3 (a wrapper
# around this interpreter) but no bq — end-to-end proof the exec happens.

def test_dispatch_execs_python_port_when_bq_absent(tmp_path):
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    script = os.path.join(repo, "scripts", "spend-checkin-costs.sh")
    tmpbin = tmp_path / "bin"
    tmpbin.mkdir()
    wrapper = tmpbin / "python3"
    wrapper.write_text(f'#!/bin/bash\nexec "{sys.executable}" "$@"\n')
    wrapper.chmod(wrapper.stat().st_mode | stat.S_IEXEC)

    proc = subprocess.run(
        ["/bin/bash", script, "--start", START, "--end", END],
        env={"PATH": str(tmpbin)},  # no bq anywhere on this PATH, no tokens
        capture_output=True, text=True, timeout=60,
    )
    assert proc.returncode == 0, proc.stderr
    result = json.loads(proc.stdout)
    assert set(result) == {"window", "bigquery", "langsmith", "apify", "errors"}
    assert result["window"] == {"start": START, "end": END}
    # bare env: every source degrades to a named errors[] entry, run stays alive
    assert result["bigquery"] is None and result["langsmith"] is None and result["apify"] is None
    joined = "\n".join(result["errors"])
    for name in ("SNAPFIX_SA_B64", "LANGSMITH_API_KEY", "APIFY_API_TOKEN"):
        assert name in joined
