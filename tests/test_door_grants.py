"""Offline tests for machine identities, per-identity grants, and the ET dial.

No GCP, no network, no fastmcp import. The composite verifier's matching logic
is a pure function; the grants map and window are plain dataclass logic on the
service layer; the write path is proven with the same fake `_execute` that
tests/test_door_write.py uses. The clock is injected — nothing here sleeps or
reads the wall clock.

Run:  .venv/bin/python -m pytest tests/test_door_grants.py -q -p no:cacheprovider
"""

from __future__ import annotations

import copy
import datetime as dt
import hashlib
import inspect
import json
import os
import sys
import time
from zoneinfo import ZoneInfo

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from door import finance_write as fw  # noqa: E402
from door.auth import (  # noqa: E402
    MACHINE_CLAIM,
    DoorConfigurationError,
    Identity,
    _identity_from_access_token,
    _match_machine_token,
    machine_token_digests,
)
from door.service import (  # noqa: E402
    CHECKIN_WRITE_TOOLS,
    CLASSIFICATION_WRITE_TOOLS,
    READ_TOOLS,
    WRITE_TOOLS,
    DoorPolicy,
    DoorService,
    _parse_grants,
)

ENROLLED = "steven@example.com"
ET = ZoneInfo("America/New_York")
KEY = "a" * 64

# The canonical grants shape scripts/deploy-door.sh carries: checkin-routine
# may write check-ins always and classify only in the window; the watchdog may
# only record failures; the smoke identity is report-reads only.
GRANTS_JSON = json.dumps(
    {
        "checkin-routine": {
            "write_tools": sorted(WRITE_TOOLS),
            "read_tools": [
                "run_finance_query",
                "saved_query",
                "list_saved_queries",
                "feed_health",
            ],
            "window": "06:45-23:00",
        },
        "checkin-watchdog": {
            "write_tools": ["record_checkin_failed"],
            "read_tools": ["run_finance_query"],
            "window": "always",
        },
        "checkin-smoke": {
            "write_tools": [],
            "read_tools": ["run_finance_query", "saved_query", "feed_health"],
            "window": "always",
        },
    }
)


def clock(hhmm: str, day: str = "2026-09-08"):
    """A frozen clock at an America/New_York wall time, RETURNED IN UTC.

    The service must convert per call; handing it UTC (not ET) is what proves
    the conversion actually happens regardless of process TZ.
    """
    hour, minute = (int(part) for part in hhmm.split(":"))
    wall = dt.datetime(*[int(p) for p in day.split("-")], hour, minute, tzinfo=ET)
    frozen = wall.astimezone(dt.timezone.utc)
    return lambda: frozen


def _service(at: str = "12:00", day: str = "2026-09-08") -> DoorService:
    policy = DoorPolicy(
        allowed_emails=frozenset({ENROLLED}), grants=_parse_grants(GRANTS_JSON)
    )
    return DoorService(policy=policy, now=clock(at, day))


def human(**kwargs) -> Identity:
    base = dict(
        subject="google|1", email=ENROLLED, email_verified=True, client_id="claude-ai"
    )
    base.update(kwargs)
    return Identity(**base)


def machine(name: str) -> Identity:
    return Identity(
        subject=f"machine|{name}", email=None, machine=name, client_id=f"machine|{name}"
    )


# ── write-path fakes (same shape as tests/test_door_write.py) ────────────────


class FakeExecute:
    def __init__(self, script=()):
        self.calls = []
        self.script = list(script)

    def __call__(self, sql, params, tool):
        self.calls.append({"sql": sql, "params": list(params), "tool": tool})
        return self.script.pop(0) if self.script else []


def fake(monkeypatch, script=()):
    fx = FakeExecute(script)
    monkeypatch.setattr(fw, "_execute", fx)
    return fx


def boom(monkeypatch):
    def _boom(sql, params, tool):
        raise AssertionError("a refused call must never reach BigQuery")

    monkeypatch.setattr(fw, "_execute", _boom)


def pval(call, name):
    for n, _t, v in call["params"]:
        if n == name:
            return v
    raise KeyError(f"{name} not in {[n for n, _, _ in call['params']]}")


def write_calls(fx):
    return [c for c in fx.calls if "BEGIN TRANSACTION" in c["sql"]]


def checkin_payload(**overrides):
    """All sources OK, so the payload passes every checkin_validate version."""
    p = {
        "run_ts": "2026-09-08T10:05:00Z",
        "consumed_checkpoint": "2026-09-07T10:00:00Z",
        "window_start": "2026-09-07T10:00:00Z",
        "window_end": "2026-09-08T10:00:00Z",
        "sources": {
            "mirror": {"status": "ok", "total": 284.12},
            "vantage": {"status": "ok", "total": 11.42},
            "live_costs": {"status": "ok", "total": 8.71},
            "mercury": {"status": "ok", "total": 1200.0},
        },
        "totals": {
            "personal_cash": 284.12,
            "mercury_cash": 1200.0,
            "cloud_billed": 11.42,
            "cloud_live": 8.71,
        },
        "report_md": "## Check-in. Total 284.12",
    }
    p.update(copy.deepcopy(overrides))
    return p


# ── the OAuth path is untouched ──────────────────────────────────────────────


def test_tool_families_cover_the_full_catalog():
    assert CHECKIN_WRITE_TOOLS == {"record_checkin", "record_checkin_failed"}
    assert len(CLASSIFICATION_WRITE_TOOLS) == 7
    assert WRITE_TOOLS == CHECKIN_WRITE_TOOLS | CLASSIFICATION_WRITE_TOOLS
    assert len(READ_TOOLS) == 6
    assert not (WRITE_TOOLS & READ_TOOLS)


def test_enrolled_oauth_identity_keeps_everything_at_any_hour():
    """Steven's existing behavior: full catalog, no window, ever."""
    for hhmm in ("03:00", "06:10", "06:44", "12:00", "23:01", "23:59"):
        service = _service(at=hhmm)
        for tool in sorted(WRITE_TOOLS | READ_TOOLS):
            assert service._authorize(human(), tool) is None, (hhmm, tool)
        assert service._write_actor(human()).window_state == "human"


def test_oauth_write_path_still_stamps_human(monkeypatch):
    fx = fake(monkeypatch, [[{"checkpoint": "2026-09-07T10:00:00Z"}], [{"write_result": "ok"}]])
    out = _service(at="03:00").record_checkin_failed(human(), "mercury token expired")
    assert out["status"] == "ok"
    (write,) = write_calls(fx)
    assert pval(write, "audit_identity") == ENROLLED
    assert pval(write, "audit_window_state") == "human"


# ── checkin-routine: check-ins always, classification only in the window ─────


def test_routine_record_checkin_before_window_stamps_autonomous(monkeypatch):
    confirmed = {
        "run_ts": "2026-09-08T10:05:00+00:00",
        "consumed_checkpoint": "2026-09-07T10:00:00+00:00",
        "window_start": "2026-09-07T10:00:00+00:00",
        "window_end": "2026-09-08T10:00:00+00:00",
        "status": "success",
    }
    fx = fake(
        monkeypatch,
        [
            [{"checkpoint": "2026-09-07T10:00:00Z"}],
            [{"write_result": "ok"}],
            [confirmed],
        ],
    )
    out = _service(at="06:10").record_checkin(
        machine("checkin-routine"), checkin_payload()
    )
    assert out["status"] == "ok"
    (write,) = write_calls(fx)
    assert pval(write, "audit_identity") == "machine|checkin-routine"
    assert pval(write, "audit_client_id") == "machine|checkin-routine"
    assert pval(write, "audit_window_state") == "autonomous"


def test_routine_classification_refused_before_window_with_named_window(monkeypatch):
    boom(monkeypatch)
    out = _service(at="06:10").reclassify_transaction(
        machine("checkin-routine"), KEY, "Groceries"
    )
    assert out["status"] == "forbidden"
    assert "06:45-23:00" in out["error"]
    assert "window" in out["error"].lower()
    assert "America/New_York" in out["error"]


def test_routine_classification_inside_window_is_human():
    service = _service(at="06:45")
    routine = machine("checkin-routine")
    assert service._authorize(routine, "reclassify_transaction") is None
    assert service._write_actor(routine).window_state == "human"


def test_routine_record_checkin_failed_allowed_at_any_hour():
    for hhmm in ("00:30", "06:10", "23:30"):
        assert (
            _service(at=hhmm)._authorize(
                machine("checkin-routine"), "record_checkin_failed"
            )
            is None
        ), hhmm


@pytest.mark.parametrize(
    "hhmm,allowed",
    [("06:44", False), ("06:45", True), ("23:00", True), ("23:01", False)],
)
def test_window_boundaries_are_inclusive(hhmm, allowed):
    refusal = _service(at=hhmm)._authorize(
        machine("checkin-routine"), "add_vendor_alias"
    )
    assert (refusal is None) is allowed, (hhmm, refusal)


@pytest.mark.parametrize(
    "hhmm,allowed",
    [("06:44", False), ("06:45", True), ("23:00", True), ("23:01", False)],
)
def test_window_boundaries_hold_under_est_not_just_edt(hhmm, allowed):
    """January (EST, UTC-5) — the offset differs from the September cases."""
    refusal = _service(at=hhmm, day="2026-01-15")._authorize(
        machine("checkin-routine"), "add_vendor_alias"
    )
    assert (refusal is None) is allowed, (hhmm, refusal)


def test_window_is_correct_when_process_tz_is_utc():
    """The dial must not care what TZ the container happens to run in."""
    old = os.environ.get("TZ")
    os.environ["TZ"] = "UTC"
    time.tzset()
    try:
        assert _service(at="06:45")._authorize(
            machine("checkin-routine"), "reclassify_transaction"
        ) is None
        refusal = _service(at="06:44")._authorize(
            machine("checkin-routine"), "reclassify_transaction"
        )
        assert refusal is not None and refusal["status"] == "forbidden"
    finally:
        if old is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = old
        time.tzset()


# ── read scope ───────────────────────────────────────────────────────────────


def test_routine_granted_read_passes_the_gate():
    service = _service(at="03:00")  # reads are not window-gated
    for tool in ("run_finance_query", "saved_query", "list_saved_queries", "feed_health"):
        assert service._authorize(machine("checkin-routine"), tool) is None, tool


def test_routine_ungranted_read_is_refused():
    out = _service(at="12:00").list_finance_sources(machine("checkin-routine"))
    assert out["status"] == "forbidden"
    assert "list_finance_sources" in out["error"]


# ── checkin-watchdog and checkin-smoke ───────────────────────────────────────


def test_watchdog_never_gets_classification_even_inside_the_window(monkeypatch):
    boom(monkeypatch)
    service = _service(at="07:05")
    watchdog = machine("checkin-watchdog")
    for tool in sorted(CLASSIFICATION_WRITE_TOOLS):
        refusal = service._authorize(watchdog, tool)
        assert refusal is not None and refusal["status"] == "forbidden", tool
        assert "not granted" in refusal["error"], tool
    assert service._authorize(watchdog, "record_checkin_failed") is None
    assert service._authorize(watchdog, "record_checkin") is not None


def test_always_window_machine_writes_stamp_autonomous():
    """'human' means inside a bounded human-hours window. A watchdog that may
    fire at any hour has no such window, so its rows honestly say autonomous."""
    actor = _service(at="12:00")._write_actor(machine("checkin-watchdog"))
    assert actor.identity == "machine|checkin-watchdog"
    assert actor.window_state == "autonomous"


def test_smoke_is_reads_only(monkeypatch):
    boom(monkeypatch)
    service = _service(at="12:00")
    smoke = machine("checkin-smoke")
    for tool in sorted(WRITE_TOOLS):
        refusal = service._authorize(smoke, tool)
        assert refusal is not None and refusal["status"] == "forbidden", tool
    for tool in ("run_finance_query", "saved_query", "feed_health"):
        assert service._authorize(smoke, tool) is None, tool


# ── default deny ─────────────────────────────────────────────────────────────


def test_machine_identity_absent_from_grants_refuses_every_governed_call(monkeypatch):
    boom(monkeypatch)
    service = _service(at="12:00")
    stranger = machine("not-in-grants")
    governed = [
        lambda: service.list_finance_sources(stranger),
        lambda: service.describe_finance_source(stranger, "gold.transactions"),
        lambda: service.run_finance_query(stranger, "SELECT 1"),
        lambda: service.list_saved_queries(stranger),
        lambda: service.saved_query(stranger, "monthly-spending"),
        lambda: service.feed_health(stranger),
        lambda: service.record_checkin(stranger, checkin_payload()),
        lambda: service.record_checkin_failed(stranger, "reason"),
        lambda: service.reclassify_transaction(stranger, KEY, "Cat"),
        lambda: service.set_vendor_override(stranger, KEY, "Wawa"),
        lambda: service.set_flow_override(stranger, KEY, "expense"),
        lambda: service.add_vendor_mapping(stranger, "Wawa", "convenience"),
        lambda: service.add_vendor_alias(stranger, "Wawa Pa", "Wawa"),
        lambda: service.add_classification_rule(stranger, "x", 1, "r", "Cat"),
        lambda: service.add_vendor_rule(stranger, "x", 1, "r", "Wawa"),
    ]
    for call in governed:
        out = call()
        assert out["status"] == "forbidden"
        assert "no grants" in out["error"]


def test_whoami_diagnoses_machine_identities():
    service = _service()
    granted = service.whoami(machine("checkin-routine"))
    assert granted["authenticated"] is True
    assert granted["authorized"] is True
    assert granted["machine"] == "checkin-routine"
    stranger = service.whoami(machine("not-in-grants"))
    assert stranger["authorized"] is False
    assert stranger["note"]


# ── grants parsing fails closed ──────────────────────────────────────────────


DIGEST = hashlib.sha256(b"x" * 32).hexdigest()
DIGESTS_JSON = json.dumps({"checkin-routine": DIGEST})


def _env(monkeypatch, *, digests=DIGESTS_JSON, grants=GRANTS_JSON):
    monkeypatch.setenv("PERSONAL_DOOR_ALLOWED_EMAILS", ENROLLED)
    monkeypatch.delenv("PERSONAL_DOOR_INSECURE_LOCAL", raising=False)
    if digests is None:
        monkeypatch.delenv("PERSONAL_DOOR_MACHINE_TOKEN_DIGESTS", raising=False)
    else:
        monkeypatch.setenv("PERSONAL_DOOR_MACHINE_TOKEN_DIGESTS", digests)
    if grants is None:
        monkeypatch.delenv("PERSONAL_DOOR_GRANTS", raising=False)
    else:
        monkeypatch.setenv("PERSONAL_DOOR_GRANTS", grants)


def test_valid_grants_with_tokens_configured_start_fine(monkeypatch):
    _env(monkeypatch)
    policy = DoorPolicy.from_env()
    assert set(policy.grants) == {"checkin-routine", "checkin-watchdog", "checkin-smoke"}


def test_tokens_without_grants_refuse_startup(monkeypatch):
    _env(monkeypatch, grants=None)
    with pytest.raises(DoorConfigurationError) as exc:
        DoorPolicy.from_env()
    assert "PERSONAL_DOOR_GRANTS" in str(exc.value)


@pytest.mark.parametrize(
    "bad_grants",
    [
        "{not json",
        '["a-list-not-a-map"]',
        '{"checkin-routine": "not-an-object"}',
        '{"checkin-routine": {"write_tools": ["no_such_tool"]}}',
        '{"checkin-routine": {"read_tools": ["record_checkin"]}}',  # a write tool
        '{"checkin-routine": {"read_tools": "some"}}',  # only "all" or a list
        '{"checkin-routine": {"window": "6:45-23:00"}}',  # HH:MM required
        '{"checkin-routine": {"window": "06:45"}}',
        '{"checkin-routine": {"window": "23:00-06:45"}}',  # no wrap-around
        '{"checkin-routine": {"windw": "always"}}',  # typo = unknown key
    ],
)
def test_malformed_grants_with_tokens_configured_refuse_startup(monkeypatch, bad_grants):
    _env(monkeypatch, grants=bad_grants)
    with pytest.raises(DoorConfigurationError):
        DoorPolicy.from_env()


def test_no_tokens_and_no_grants_is_the_pre_u10_door(monkeypatch):
    _env(monkeypatch, digests=None, grants=None)
    policy = DoorPolicy.from_env()
    assert policy.grants == {}


@pytest.mark.parametrize(
    "bad_digests",
    [
        "{not json",
        '["list"]',
        '{"checkin-routine": "not-hex"}',
        '{"checkin-routine": "ABC"}',
        f'{{"": "{DIGEST}"}}',
        f'{{"checkin-routine": "{DIGEST.upper()}"}}',  # lowercase hex only
    ],
)
def test_malformed_digests_refuse_startup(monkeypatch, bad_digests):
    _env(monkeypatch, digests=bad_digests)
    with pytest.raises(DoorConfigurationError):
        DoorPolicy.from_env()


# ── the composite token verifier's matching core ─────────────────────────────


TOKEN = "5f4dcc3b5aa765d61d8327deb882cf995f4dcc3b5aa765d61d8327deb882cf99"


def test_digest_match_names_the_machine_identity():
    digests = {
        "checkin-routine": hashlib.sha256(TOKEN.encode()).hexdigest(),
        "checkin-smoke": hashlib.sha256(b"other").hexdigest(),
    }
    assert _match_machine_token(TOKEN, digests) == "checkin-routine"


def test_near_miss_token_does_not_match():
    digests = {"checkin-routine": hashlib.sha256(TOKEN.encode()).hexdigest()}
    assert _match_machine_token(TOKEN[:-1] + "x", digests) is None
    assert _match_machine_token("", digests) is None
    assert _match_machine_token(TOKEN, {}) is None


def test_matching_uses_constant_time_compare():
    """Guard the construction: SHA-256 the presented token, then
    secrets.compare_digest against every configured digest — no early break,
    no `==` on secret-derived strings."""
    src = inspect.getsource(_match_machine_token)
    assert "secrets.compare_digest" in src
    assert "hashlib.sha256" in src
    assert "break" not in src


def test_machine_token_digests_env_parses(monkeypatch):
    monkeypatch.setenv(
        "PERSONAL_DOOR_MACHINE_TOKEN_DIGESTS",
        json.dumps({"checkin-routine": DIGEST, "checkin-smoke": DIGEST}),
    )
    assert machine_token_digests() == {
        "checkin-routine": DIGEST,
        "checkin-smoke": DIGEST,
    }
    monkeypatch.delenv("PERSONAL_DOOR_MACHINE_TOKEN_DIGESTS")
    assert machine_token_digests() == {}


# ── identity synthesis from the transport token ──────────────────────────────


class _StubToken:
    def __init__(self, claims, client_id="client-1", subject=None, scopes=()):
        self.claims = claims
        self.client_id = client_id
        self.subject = subject
        self.scopes = list(scopes)


def test_machine_claim_becomes_a_machine_identity():
    token = _StubToken(
        claims={MACHINE_CLAIM: "checkin-routine"},
        client_id="machine|checkin-routine",
        # Transport artifact: the token carries Google's required scopes only
        # to satisfy RequireAuthMiddleware. They must NOT surface as identity.
        scopes=["openid", "profile"],
    )
    identity = _identity_from_access_token(token)
    assert identity.machine == "checkin-routine"
    assert identity.subject == "machine|checkin-routine"
    assert identity.email is None
    assert identity.scopes == ()


def test_google_claims_still_become_the_human_identity():
    token = _StubToken(
        claims={
            "sub": "google|1",
            "email": "Steven@Example.com",
            "email_verified": "true",
            "name": "Steven",
        },
        client_id="claude-ai",
        scopes=["openid"],
    )
    identity = _identity_from_access_token(token)
    assert identity.machine is None
    assert identity.email == ENROLLED
    assert identity.email_verified is True
    assert identity.subject == "google|1"
