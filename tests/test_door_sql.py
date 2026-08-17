"""Offline tests for the door's SQL perimeter and identity gate.

No GCP, no network. Both units under test are pure functions or plain dataclass
logic, which is the point: the two controls that matter most are the two that
can be proven on a laptop in under a second.

Run:  python3 -m pytest tests/ -q
"""

from __future__ import annotations

import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from door import finance_native as fn  # noqa: E402
from door.auth import Identity, _email_verified_claim  # noqa: E402
from door.service import DoorPolicy, DoorService  # noqa: E402

OK = f"SELECT 1 FROM `{fn.PROJECT}.{fn.GOLD}.transactions`"


# ── the SQL perimeter ────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "sql",
    [
        OK,
        f"SELECT * FROM {fn.GOLD}.transactions",
        f"SELECT * FROM `{fn.PROJECT}.{fn.FINANCE}.v_spending`",
        # A CTE name is unqualified, so it must pass through unchallenged.
        f"WITH t AS (SELECT * FROM {fn.GOLD}.transactions) SELECT * FROM t",
        # A trailing semicolon is stripped, not rejected.
        OK + ";",
        # Whitelisted names inside string literals must not be mistaken for refs.
        f"SELECT 'tiller_raw.transactions_external' AS s FROM {fn.GOLD}.transactions",
    ],
)
def test_accepts_governed_reads(sql):
    statement, error = fn._validate_query(sql)
    assert error is None, f"unexpectedly rejected: {error}"
    assert statement


@pytest.mark.parametrize(
    "sql,expected",
    [
        ("", "sql is required"),
        (f"DELETE FROM {fn.GOLD}.transactions", "only a SELECT"),
        (f"SELECT * FROM {fn.GOLD}.transactions; DROP TABLE x", "only one SQL statement"),
        (f"SELECT * FROM {fn.GOLD}.transactions UNION ALL SELECT * FROM x; DELETE FROM y", "only one SQL statement"),
        # A real table in a governed dataset that is not on the whitelist.
        (f"SELECT * FROM {fn.GOLD}.transaction_onboarding_runs", "outside the governed catalog"),
        (f"SELECT * FROM {fn.FINANCE}.transactions", "outside the governed catalog"),
        # tiller_raw is banned and says why.
        ("SELECT * FROM tiller_raw.transactions_external", "tiller_raw"),
        # Another project is out of bounds even for a real-looking table.
        (f"SELECT * FROM `other-project.{fn.GOLD}.transactions`", "outside this project"),
        # Model/remote functions.
        (f"SELECT ML.PREDICT(1) FROM {fn.GOLD}.transactions", "model/AI functions"),
        ("SELECT * FROM EXTERNAL_QUERY('x', 'y')", "remote queries"),
    ],
)
def test_rejects(sql, expected):
    statement, error = fn._validate_query(sql)
    assert statement is None
    assert expected in error, f"got {error!r}"


def test_comment_cannot_smuggle_a_source():
    """A whitelisted table in a comment must not launder an ungoverned FROM."""
    sql = f"SELECT * /* {fn.GOLD}.transactions */ FROM tiller_raw.transactions_external"
    statement, error = fn._validate_query(sql)
    assert statement is None
    assert "tiller_raw" in error


def test_comment_cannot_hide_a_second_statement():
    sql = f"SELECT 1 FROM {fn.GOLD}.transactions -- ;DROP TABLE x\n"
    statement, error = fn._validate_query(sql)
    assert error is None, "a semicolon inside a comment is not a second statement"
    assert statement


def test_every_whitelisted_source_is_two_part():
    """SOURCES keys are 'dataset.table' and only name governed datasets."""
    for name in fn.SOURCES:
        parts = name.split(".")
        assert len(parts) == 2, name
        assert parts[0] in (fn.FINANCE, fn.GOLD), name


def test_no_raw_dataset_anywhere_in_the_catalog():
    assert not [n for n in fn.SOURCES if n.startswith("tiller")]


def test_every_saved_query_is_runnable():
    """A vetted query that the whitelist silently breaks is the worst outcome:
    it looks supported and fails only when someone asks the question."""
    from door import saved_queries

    catalog = saved_queries.list_saved_queries()
    blocked = [
        (q["name"], q["blocked_because"]) for q in catalog["queries"] if not q["runnable"]
    ]
    assert not blocked, f"saved queries blocked by the whitelist: {blocked}"


# ── redaction ────────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "column,redacted",
    [
        ("account_number", True),
        ("card_number", True),
        ("routing_number", True),
        # Masks are already truncated and are how same-named accounts are told
        # apart — redacting them would break feed_health.
        ("account_number_masked", False),
        ("account_name", False),
        ("spend_amount", False),
    ],
)
def test_redaction_targets_full_numbers_only(column, redacted):
    assert fn._should_redact(column) is redacted


def test_redact_row_leaves_empty_values_alone():
    row = fn._redact_row({"account_number": None, "account_name": "Chase"})
    assert row == {"account_number": None, "account_name": "Chase"}


# ── the identity gate ────────────────────────────────────────────────────────


ENROLLED = "steven@example.com"


def _service() -> DoorService:
    return DoorService(policy=DoorPolicy(allowed_emails=frozenset({ENROLLED})))


def _identity(**kwargs) -> Identity:
    base = dict(subject="google|1", email=ENROLLED, email_verified=True)
    base.update(kwargs)
    return Identity(**base)


def test_enrolled_identity_passes():
    assert _service()._authorize(_identity()) is None


@pytest.mark.parametrize(
    "identity,status",
    [
        (Identity(subject=None, email=None), "unauthorized"),
        (Identity(subject="google|1", email=None), "unauthorized"),
        # Verified-email check comes before the allowlist check.
        (Identity(subject="google|1", email=ENROLLED, email_verified=False), "forbidden"),
        (Identity(subject="google|1", email=ENROLLED, email_verified=None), "forbidden"),
        (Identity(subject="google|2", email="someone@else.com", email_verified=True), "forbidden"),
    ],
)
def test_refuses(identity, status):
    refusal = _service()._authorize(identity)
    assert refusal is not None
    assert refusal["status"] == status


def test_allowlist_is_case_and_space_insensitive():
    service = DoorService(policy=DoorPolicy(allowed_emails=frozenset({ENROLLED})))
    assert service._authorize(_identity(email="  STEVEN@Example.com  ".strip().lower())) is None


def test_empty_allowlist_refuses_to_start(monkeypatch):
    """No permissive default — the allowlist is the only perimeter."""
    monkeypatch.delenv("PERSONAL_DOOR_INSECURE_LOCAL", raising=False)
    monkeypatch.setenv("PERSONAL_DOOR_ALLOWED_EMAILS", "")
    with pytest.raises(Exception) as exc:
        DoorPolicy.from_env()
    assert "allowlist" in str(exc.value).lower() or "empty" in str(exc.value).lower()


def test_whoami_is_ungated_but_reports_unauthorized():
    """A wrong-account connection must diagnose itself, while yielding no data."""
    out = _service().whoami(
        Identity(subject="google|2", email="someone@else.com", email_verified=True)
    )
    assert out["authenticated"] is True
    assert out["authorized"] is False
    assert out["note"]


def test_every_governed_method_refuses_a_stranger():
    """The gate is a property of the service layer, not of each tool."""
    service = _service()
    stranger = Identity(subject="google|2", email="nope@else.com", email_verified=True)
    governed = [
        lambda: service.list_finance_sources(stranger),
        lambda: service.describe_finance_source(stranger, f"{fn.GOLD}.transactions"),
        lambda: service.run_finance_query(stranger, OK),
        lambda: service.list_saved_queries(stranger),
        lambda: service.saved_query(stranger, "monthly-spending"),
        lambda: service.feed_health(stranger),
    ]
    for call in governed:
        assert call()["status"] == "forbidden"


# ── Google's string-typed claim ──────────────────────────────────────────────


@pytest.mark.parametrize(
    "raw,expected",
    [
        (True, True),
        (False, False),
        ("true", True),
        # The bug this exists to prevent: truthiness would accept "false".
        ("false", False),
        ("TRUE", True),
        (None, None),
        ("", None),
    ],
)
def test_email_verified_claim_normalization(raw, expected):
    assert _email_verified_claim(raw) is expected


# ── Firestore key encoding ───────────────────────────────────────────────────


def test_firestore_sanitizer_handles_url_shaped_client_ids():
    """claude.ai registers with a client_id that is a URL, and Firestore
    document IDs cannot contain '/'. Without an explicit sanitization strategy
    the first OAuth callback 500s with 'lacks a collection id' — which reaches
    the user as a bare Internal Server Error naming nothing useful."""
    firestore = pytest.importorskip("key_value.aio.stores.firestore")
    strategy = firestore.FirestoreV1KeySanitizationStrategy()

    real_client_id = "https://claude.ai/oauth/mcp-oauth-client-metadata"
    for key in (real_client_id, "", "..", "__reserved__", "plain-key"):
        out = strategy.sanitize(key)
        assert "/" not in out, f"{key!r} sanitized to something Firestore rejects"
        assert out, f"{key!r} sanitized to empty"

    # Distinct inputs must not collide into one stored registration.
    a = strategy.sanitize(real_client_id)
    b = strategy.sanitize(real_client_id + "-other")
    assert a != b


def test_auth_wires_the_sanitizers():
    """Guard the wiring, not just the library: these default to None, so
    omitting them is silent until a real client connects."""
    import inspect

    from door import auth

    src = inspect.getsource(auth.build_auth)
    assert "FirestoreV1KeySanitizationStrategy()" in src
    assert "FirestoreV1CollectionSanitizationStrategy()" in src


# ── mirror-level staleness ───────────────────────────────────────────────────


def _fake_mirror(monkeypatch, days, newest="2026-08-11"):
    from door import finance_native, saved_queries

    def fake(sql, max_rows=100, dry_run=False):
        return {
            "status": "ok",
            "results": [
                {"newest_transaction_anywhere": newest, "days_since_newest": days}
            ],
        }

    monkeypatch.setattr(finance_native, "run_finance_query", fake)
    return saved_queries


def test_mirror_stall_is_flagged(monkeypatch):
    """The failure per-account staleness structurally cannot see: when the hourly
    job dies, every account freezes together, so the relative comparison looks
    normal. This happened for five days (2026-08-12 to 08-17) on one bad cell."""
    sq = _fake_mirror(monkeypatch, days=6)
    out = sq.mirror_health()
    assert out["mirror_suspect"] is True
    assert "broken" in out["verdict"].lower()


def test_normal_feed_lag_is_not_flagged(monkeypatch):
    """Bank feeds lag a day or two — that must not cry wolf."""
    sq = _fake_mirror(monkeypatch, days=1)
    assert sq.mirror_health()["mirror_suspect"] is False


def test_feed_health_surfaces_the_mirror_verdict(monkeypatch):
    from door import finance_native, saved_queries

    def fake(sql, max_rows=100, dry_run=False):
        if "newest_transaction_anywhere" in sql:
            return {
                "status": "ok",
                "results": [
                    {"newest_transaction_anywhere": "2026-08-11", "days_since_newest": 6}
                ],
            }
        return {"status": "ok", "results": [], "result_count": 0}

    monkeypatch.setattr(finance_native, "run_finance_query", fake)
    out = saved_queries.feed_health()
    assert out["mirror"]["mirror_suspect"] is True
    assert "CHECK `mirror` FIRST" in out["how_to_read"]
