"""Offline tests for the door's write tools (door/finance_write.py).

No GCP, no network. The write layer is split into pure logic (validation,
sanitization, SQL/param construction, audit-row construction) and a single
execution touchpoint (`_execute`), which these tests replace with a fake —
mirroring how tests/test_door_sql.py proves the read perimeter offline.

Run:  .venv/bin/python -m pytest tests/test_door_write.py -q -p no:cacheprovider
"""

from __future__ import annotations

import copy
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from door import finance_write as fw  # noqa: E402
from door.auth import Identity  # noqa: E402
from door.service import DoorPolicy, DoorService  # noqa: E402

# A legitimate 64-hex transaction key that CONTAINS a 16-digit run — repo keys
# are TO_HEX(SHA256(...)), so long digit runs inside them are normal and must
# never be mistaken for an account number.
KEY = "a" * 24 + "1234567890123456" + "b" * 24
assert len(KEY) == 64

ACTOR = fw.WriteActor(identity="steven@example.com", client_id="client-1", window_state="human")

WRITE_OK = [{"write_result": "ok"}]
WRITE_NOOP = [{"write_result": "no-op"}]


class FakeExecute:
    """Stands in for fw._execute: records every job, replays scripted results."""

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


def pval(call, name):
    for n, _t, v in call["params"]:
        if n == name:
            return v
    raise KeyError(f"{name} not in {[n for n, _, _ in call['params']]}")


def audit_calls(fx):
    return [c for c in fx.calls if "door_audit_log" in c["sql"]]


def write_calls(fx):
    return [c for c in fx.calls if "BEGIN TRANSACTION" in c["sql"]]


def checkin_payload(**overrides):
    p = {
        "run_ts": "2026-09-08T10:05:00Z",
        "consumed_checkpoint": "2026-09-07T10:00:00Z",
        "window_start": "2026-09-07T10:00:00Z",
        "window_end": "2026-09-08T10:00:00Z",
        "sources": {
            "mirror": {"status": "ok", "total": 284.12},
            "vantage": {"status": "ok", "total": 11.42},
            "live_costs": {"status": "ok", "total": 8.71},
            "mercury": {"status": "failed", "total": None, "note": "token expired"},
        },
        "totals": {"personal_cash": 284.12, "mercury_cash": None,
                   "cloud_billed": 11.42, "cloud_live": 8.71},
        "report_md": "## Check-in\nDEGRADED \u2014 mercury unavailable\nCard ****1234 ok. Total $284.12",
    }
    p.update(copy.deepcopy(overrides))
    return p


# ── pure: field validation ───────────────────────────────────────────────────


def test_transaction_key_shape():
    assert fw.validate_transaction_key(KEY) is None
    assert fw.validate_transaction_key("a" * 64) is None
    for bad in ("", "a" * 63, "A" * 64, "g" * 64, "a" * 65, None, 42):
        assert fw.validate_transaction_key(bad) is not None, bad


@pytest.mark.parametrize(
    "value,ok",
    [
        ("Groceries", True),
        ("Card ****1234", True),
        ("acct 123456789", False),          # 9-digit run
        ("4111111111111111", False),        # 16-digit run
        ("two\nlines", False),
        ("x" * 500, False),
        ("", False),                        # required
    ],
)
def test_field_error_polices_structured_fields(value, ok):
    err = fw.field_error("category", value)
    assert (err is None) is ok, err


def test_field_error_optional_allows_empty():
    assert fw.field_error("notes", "", required=False) is None


# ── pure: failed-reason sanitization ─────────────────────────────────────────


def test_clean_reason_lands_verbatim():
    reason, code = fw.sanitize_fail_reason("mercury token expired")
    assert reason == "mercury token expired"
    assert code is None


def test_empty_reason_defaults_like_the_bash_twin():
    reason, code = fw.sanitize_fail_reason("")
    assert reason == "unspecified"
    assert code is None


@pytest.mark.parametrize(
    "raw,expected_code",
    [
        ("card 4111111111111111 declined", "digit-run"),
        ("line one\nline two", "multiline"),
        ("x" * 301, "overlong"),
    ],
)
def test_bad_reason_replaced_with_enumerated_code(raw, expected_code):
    reason, code = fw.sanitize_fail_reason(raw)
    assert code == expected_code
    assert reason in fw.REASON_CODES.values()
    assert "4111111111111111" not in reason
    assert "\n" not in reason and len(reason) <= 300


# ── pure: audit scrubbing ────────────────────────────────────────────────────


def test_scrub_exempts_hex_keys_and_redacts_digit_runs():
    scrubbed = fw.scrub_audit_value(
        {"transaction_key": KEY, "note": "acct 1234567890123456", "n": 3}
    )
    assert scrubbed["transaction_key"] == KEY
    assert "1234567890123456" not in scrubbed["note"]
    assert scrubbed["n"] == 3


# ── pure: transactional job shape ────────────────────────────────────────────


def test_transactional_job_bundles_dml_and_audit_atomically():
    sql, params = fw.build_transactional(
        tool="reclassify_transaction",
        actor=ACTOR,
        args_json="{}",
        dml_sql="INSERT INTO t (a) VALUES (@a)",
        dml_params=[("a", "STRING", "x")],
        row_key="transaction_key=" + KEY,
    )
    assert "BEGIN TRANSACTION" in sql and "COMMIT TRANSACTION" in sql
    assert "@@row_count" in sql
    assert "door_audit_log" in sql
    assert sql.rstrip().rstrip(";").endswith("AS write_result")
    names = [n for n, _t, _v in params]
    assert "a" in names and "audit_args" in names
    ok = next(v for n, _t, v in params if n == "audit_result_ok")
    noop = next(v for n, _t, v in params if n == "audit_result_noop")
    assert ok == f"ok key=transaction_key={KEY}"
    assert noop == f"no-op key=transaction_key={KEY}"
    ident = next(v for n, _t, v in params if n == "audit_identity")
    assert ident == "steven@example.com"


def test_no_delete_or_bare_update_in_any_write_sql():
    """DELETE exists nowhere; UPDATE only inside the two keyed MERGE upserts."""
    jobs = {
        "reclassify": fw._reclassify_dml(),
        "vendor_override": fw._vendor_override_dml(),
        "flow_override": fw._flow_override_dml(),
        "mapping": fw._mapping_dml(),
        "alias": fw._alias_dml(),
        "classification_rule": fw._classification_rule_dml(),
        "vendor_rule": fw._vendor_rule_dml(),
        "checkin": fw._checkin_merge_dml(),
        "checkin_failed": fw._checkin_failed_dml(),
    }
    for name, sql in jobs.items():
        assert "DELETE" not in sql.upper(), name
        if name in ("mapping", "alias"):
            assert "WHEN MATCHED THEN UPDATE" in sql, name
        else:
            assert "UPDATE" not in sql.upper(), name


# ── record_checkin ───────────────────────────────────────────────────────────


def test_checkin_success_builds_canonical_merge_and_confirms(monkeypatch):
    confirmed = {
        "run_ts": "2026-09-08T10:05:00+00:00",
        "consumed_checkpoint": "2026-09-07T10:00:00+00:00",
        "window_start": "2026-09-07T10:00:00+00:00",
        "window_end": "2026-09-08T10:00:00+00:00",
        "status": "success",
    }
    fx = fake(monkeypatch, [
        [{"checkpoint": "2026-09-07T10:00:00Z"}],
        WRITE_OK,
        [confirmed],
    ])
    out = fw.record_checkin(checkin_payload(), actor=ACTOR)
    assert out["status"] == "ok"
    assert out["row"]["status"] == "success"

    (write,) = write_calls(fx)
    assert "MERGE" in write["sql"] and "checkin_reports" in write["sql"]
    assert "T.status = 'success'" in write["sql"]
    assert "WHEN NOT MATCHED THEN INSERT" in write["sql"]
    assert "WHEN MATCHED" not in write["sql"]  # a double fire can never mutate
    # Canonicalized parameters, exactly as checkin-write.sh would pass them.
    assert pval(write, "window_start") == "2026-09-07T10:00:00Z"
    assert pval(write, "consumed_checkpoint") == "2026-09-07T10:00:00Z"
    assert json.loads(pval(write, "sources"))["mirror"]["total"] == 284.12
    assert pval(write, "audit_tool") == "record_checkin"
    assert pval(write, "audit_result_ok").startswith("ok key=window_start=")


def test_checkin_same_window_second_success_is_noop(monkeypatch):
    fx = fake(monkeypatch, [
        [{"checkpoint": "2026-09-07T10:00:00Z"}],
        WRITE_NOOP,
        [{"window_start": "2026-09-07T10:00:00+00:00", "status": "success"}],
    ])
    out = fw.record_checkin(checkin_payload(), actor=ACTOR)
    assert out["status"] == "no-op"
    (write,) = write_calls(fx)
    assert pval(write, "audit_result_noop").startswith("no-op key=window_start=")


def test_checkin_checkpoint_moved_refuses_before_any_dml(monkeypatch):
    fx = fake(monkeypatch, [[{"checkpoint": "2026-09-08T10:00:00Z"}]])
    out = fw.record_checkin(checkin_payload(), actor=ACTOR)
    assert out["status"] == "refused"
    assert out["reason"] == "checkpoint-moved"
    assert write_calls(fx) == []
    (audit,) = audit_calls(fx)
    assert pval(audit, "audit_result").startswith("refused:checkpoint-moved")


def test_checkin_invalid_payload_refused_with_audit(monkeypatch):
    fx = fake(monkeypatch)
    p = checkin_payload()
    del p["report_md"]
    out = fw.record_checkin(p, actor=ACTOR)
    assert out["status"] == "refused"
    assert out["reason"] == "invalid-payload"
    assert any("report_md" in e for e in out["detail"])
    assert write_calls(fx) == []
    (audit,) = audit_calls(fx)
    assert "BEGIN TRANSACTION" not in audit["sql"]
    assert pval(audit, "audit_result") == "refused:invalid-payload"


def test_checkin_digit_run_refusal_never_lands_the_digits(monkeypatch):
    fx = fake(monkeypatch)
    p = checkin_payload()
    p["report_md"] += " acct 4111111111111111"
    out = fw.record_checkin(p, actor=ACTOR)
    assert out["status"] == "refused"
    (audit,) = audit_calls(fx)
    for _n, _t, v in audit["params"]:
        assert "4111111111111111" not in str(v)
    assert all("4111111111111111" not in d for d in out["detail"])


# ── record_checkin_failed ────────────────────────────────────────────────────


def test_checkin_failed_lands_zero_length_window(monkeypatch):
    fx = fake(monkeypatch, [
        [{"checkpoint": "2026-09-07T10:00:00Z"}],
        WRITE_OK,
    ])
    out = fw.record_checkin_failed("mercury token expired", actor=ACTOR)
    assert out["status"] == "ok"
    assert out["row"]["fail_reason"] == "mercury token expired"
    (write,) = write_calls(fx)
    assert "checkin_reports" in write["sql"]
    assert pval(write, "window_start") == "2026-09-07T10:00:00Z"
    # Zero-length window: the INSERT reuses @window_start for window_end.
    assert write["sql"].count("@window_start") == 2
    assert pval(write, "reason") == "mercury token expired"


def test_checkin_failed_sanitizes_but_still_lands(monkeypatch):
    fx = fake(monkeypatch, [
        [{"checkpoint": "2026-09-07T10:00:00Z"}],
        WRITE_OK,
    ])
    out = fw.record_checkin_failed("card 4111111111111111 declined", actor=ACTOR)
    assert out["status"] == "ok"                      # recording never fails
    assert out["sanitized"] == "digit-run"
    (write,) = write_calls(fx)
    landed = pval(write, "reason")
    assert "4111111111111111" not in landed
    assert landed in fw.REASON_CODES.values()
    assert " sanitized=digit-run" in pval(write, "audit_result_ok")


def test_checkin_failed_first_run_anchors_at_now(monkeypatch):
    fx = fake(monkeypatch, [[{"checkpoint": "none"}], WRITE_OK])
    out = fw.record_checkin_failed("no data", actor=ACTOR)
    assert out["status"] == "ok"
    (write,) = write_calls(fx)
    assert pval(write, "consumed_checkpoint") == ""
    assert pval(write, "window_start")  # anchored at now, non-empty


# ── reclassify_transaction ───────────────────────────────────────────────────


def test_reclassify_happy_returns_landing_proof(monkeypatch):
    fx = fake(monkeypatch, [
        [{"transaction_key": KEY}],                                # existence
        WRITE_OK,
        [{"transaction_key": KEY, "category": "Groceries",
          "notes": None, "created_at": "2026-09-08T10:05:00+00:00"}],
        [{"transaction_key": KEY, "category": "Groceries",
          "subcategory": None, "classification_source": "override"}],
    ])
    out = fw.reclassify_transaction(KEY, "Groceries", actor=ACTOR)
    assert out["status"] == "ok"
    assert out["row"]["category"] == "Groceries"
    assert out["classification_proof"]["classification_source"] == "override"

    (write,) = write_calls(fx)
    assert "INSERT INTO" in write["sql"] and "transaction_overrides" in write["sql"]
    assert pval(write, "transaction_key") == KEY
    assert pval(write, "audit_result_ok") == f"ok key=transaction_key={KEY}"


def test_reclassify_unknown_transaction_refused(monkeypatch):
    fx = fake(monkeypatch, [[]])  # existence probe finds nothing
    out = fw.reclassify_transaction(KEY, "Groceries", actor=ACTOR)
    assert out["status"] == "refused"
    assert out["reason"] == "unknown-transaction"
    assert write_calls(fx) == []
    (audit,) = audit_calls(fx)
    assert pval(audit, "audit_result").startswith("refused:unknown-transaction")


def test_reclassify_hex_key_accepted_digit_run_elsewhere_refused(monkeypatch):
    fx = fake(monkeypatch)
    out = fw.reclassify_transaction(KEY, "Groceries",
                                    notes="acct 1234567890123456", actor=ACTOR)
    assert out["status"] == "refused"
    assert out["reason"] == "invalid-field"
    (audit,) = audit_calls(fx)
    args = json.loads(pval(audit, "audit_args"))
    assert args["transaction_key"] == KEY      # legit hex survives intact
    assert "1234567890123456" not in json.dumps({k: v for k, v in args.items()
                                                 if k != "transaction_key"})


def test_reclassify_bad_key_shape_refused(monkeypatch):
    fx = fake(monkeypatch)
    out = fw.reclassify_transaction("not-a-key", "Groceries", actor=ACTOR)
    assert out["status"] == "refused"
    assert out["reason"] == "invalid-transaction-key"
    assert len(audit_calls(fx)) == 1


def test_duplicate_reclassify_appends_twice_two_audits(monkeypatch):
    script = []
    for category in ("Groceries", "Restaurants"):
        script += [
            [{"transaction_key": KEY}],
            WRITE_OK,
            [{"transaction_key": KEY, "category": category}],
            [{"transaction_key": KEY, "category": category,
              "classification_source": "override"}],
        ]
    fx = fake(monkeypatch, script)
    fw.reclassify_transaction(KEY, "Groceries", actor=ACTOR)
    out = fw.reclassify_transaction(KEY, "Restaurants", actor=ACTOR)
    # Two audit rows, two appended INSERTs, zero UPDATE/DELETE: one effective
    # classification because v_transactions_classified takes latest created_at.
    assert len(audit_calls(fx)) == 2
    assert len(write_calls(fx)) == 2
    for w in write_calls(fx):
        assert "UPDATE" not in w["sql"].split("door_audit_log")[0].upper()
    assert "latest" in out["semantics"]


# ── vendor / flow overrides ──────────────────────────────────────────────────


def test_vendor_override_appends(monkeypatch):
    fx = fake(monkeypatch, [
        WRITE_OK,
        [{"transaction_key": KEY, "vendor_name": "Shake Shack"}],
    ])
    out = fw.set_vendor_override(KEY, "Shake Shack", actor=ACTOR)
    assert out["status"] == "ok"
    assert out["row"]["vendor_name"] == "Shake Shack"
    (write,) = write_calls(fx)
    assert "transaction_vendor_overrides" in write["sql"]
    assert "materializes within the hour" in out["materialization"]


def test_flow_override_validates_flow_type(monkeypatch):
    fx = fake(monkeypatch)
    out = fw.set_flow_override(KEY, "totally not a flow!", actor=ACTOR)
    assert out["status"] == "refused"
    assert out["reason"] == "invalid-flow-type"
    assert len(audit_calls(fx)) == 1

    fx2 = fake(monkeypatch, [WRITE_OK, [{"transaction_key": KEY,
                                         "flow_type": "internal_transfer"}]])
    out = fw.set_flow_override(KEY, "internal_transfer", actor=ACTOR)
    assert out["status"] == "ok"
    (write,) = write_calls(fx2)
    assert "transaction_flow_overrides" in write["sql"]


# ── vendor_category_map / vendor_aliases upserts ────────────────────────────


def test_mapping_validates_category_against_live_typology(monkeypatch):
    fx = fake(monkeypatch, [
        [{"category_id": "groceries"}, {"category_id": "restaurants"}],
    ])
    out = fw.add_vendor_mapping("Giant Heirloom", "grocries", actor=ACTOR)
    assert out["status"] == "refused"
    assert out["reason"] == "unknown-category"
    assert "groceries" in out["valid_category_ids"]
    (audit,) = audit_calls(fx)
    assert pval(audit, "audit_result").startswith("refused:unknown-category")


def test_mapping_happy_is_merge_upsert(monkeypatch):
    fx = fake(monkeypatch, [
        [{"category_id": "groceries"}],
        WRITE_OK,
        [{"vendor_name": "Giant Heirloom", "category_id": "groceries",
          "enabled": True}],
    ])
    out = fw.add_vendor_mapping("Giant Heirloom", "groceries", actor=ACTOR)
    assert out["status"] == "ok"
    (write,) = write_calls(fx)
    assert "MERGE" in write["sql"] and "vendor_category_map" in write["sql"]
    assert "WHEN MATCHED THEN UPDATE" in write["sql"]


def test_alias_upsert_twice_takes_merge_path_not_append(monkeypatch):
    script = [
        WRITE_OK, [{"alias_key": "shakeshackpa", "canonical_vendor_name": "Shake Shack"}],
        WRITE_OK, [{"alias_key": "shakeshackpa", "canonical_vendor_name": "Shack II"}],
    ]
    fx = fake(monkeypatch, script)
    fw.add_vendor_alias("Shake Shack Pa", "Shake Shack", actor=ACTOR)
    out = fw.add_vendor_alias("Shake Shack Pa", "Shack II", actor=ACTOR)
    assert out["status"] == "ok"
    assert len(write_calls(fx)) == 2
    for w in write_calls(fx):
        # MERGE on the normalized alias_key: a re-ask updates the ONE row
        # rather than fanning duplicate alias_key rows into the gold join.
        assert "MERGE" in w["sql"] and "vendor_aliases" in w["sql"]
        assert "WHEN MATCHED THEN UPDATE" in w["sql"]
        assert "REGEXP_REPLACE(LOWER(@alias_name)" in w["sql"]
        assert pval(w, "audit_result_ok") == "ok key=alias_key=shakeshackpa"


def test_alias_normalizing_to_empty_key_refused(monkeypatch):
    fx = fake(monkeypatch)
    out = fw.add_vendor_alias("***", "Shake Shack", actor=ACTOR)
    assert out["status"] == "refused"
    assert out["reason"] == "invalid-field"
    assert len(audit_calls(fx)) == 1


# ── rules ────────────────────────────────────────────────────────────────────


def test_classification_rule_appends_with_proof_query(monkeypatch):
    fx = fake(monkeypatch, [
        WRITE_OK,
        [{"rule_id": "wawa", "priority": 20, "category": "Convenience",
          "enabled": True}],
        [{"transaction_key": "k", "category": "Convenience",
          "classification_source": "rule:wawa"}],
    ])
    out = fw.add_classification_rule("wawa", 20, r"(?i)\bwawa\b", "Convenience",
                                     actor=ACTOR)
    assert out["status"] == "ok"
    assert out["classification_proof"][0]["classification_source"] == "rule:wawa"
    (write,) = write_calls(fx)
    assert "classification_rules" in write["sql"]
    assert "'expense'" in write["sql"]           # ported fixed direction
    assert "REGEXP_CONTAINS(''" in write["sql"]  # regex validity guard
    proof = fx.calls[-1]
    assert "v_transactions_classified" in proof["sql"]
    assert "LIMIT" in proof["sql"]


@pytest.mark.parametrize("priority", [-1, "abc", None, 1.5])
def test_rule_priority_must_be_nonnegative_int(monkeypatch, priority):
    fx = fake(monkeypatch)
    out = fw.add_classification_rule("x", priority, "regex", "Cat", actor=ACTOR)
    assert out["status"] == "refused"
    assert out["reason"] == "invalid-priority"
    assert len(audit_calls(fx)) == 1


def test_vendor_rule_appends_with_regex_guard(monkeypatch):
    fx = fake(monkeypatch, [
        WRITE_OK,
        [{"rule_id": "wawa", "vendor_name": "Wawa", "enabled": True}],
    ])
    out = fw.add_vendor_rule("wawa", 20, r"(?i)\bwawa\b", "Wawa", actor=ACTOR)
    assert out["status"] == "ok"
    (write,) = write_calls(fx)
    assert "vendor_rules" in write["sql"]
    assert "REGEXP_CONTAINS(''" in write["sql"]


# ── audit invariants across all tools ────────────────────────────────────────


def test_every_accepted_write_carries_audit_in_same_job(monkeypatch):
    """DML and audit land or fail together: one job, one transaction."""
    fx = fake(monkeypatch, [WRITE_OK, [{"transaction_key": KEY}]])
    fw.set_vendor_override(KEY, "Wawa", actor=ACTOR)
    (write,) = write_calls(fx)
    assert "door_audit_log" in write["sql"]
    assert write["sql"].index("BEGIN TRANSACTION") < write["sql"].index("door_audit_log")
    assert write["sql"].index("door_audit_log") < write["sql"].index("COMMIT TRANSACTION")


def test_every_refusal_lands_a_plain_audit_insert(monkeypatch):
    """Validation refusals never reach DML but still leave one audit row."""
    cases = [
        lambda: fw.reclassify_transaction("bad", "Cat", actor=ACTOR),
        lambda: fw.set_vendor_override(KEY, "", actor=ACTOR),
        lambda: fw.set_flow_override(KEY, "NOPE!", actor=ACTOR),
        lambda: fw.add_vendor_alias("", "Canonical", actor=ACTOR),
        lambda: fw.add_classification_rule("x", -1, "r", "Cat", actor=ACTOR),
        lambda: fw.add_vendor_rule("x", 1, "", "Wawa", actor=ACTOR),
    ]
    for case in cases:
        fx = fake(monkeypatch)
        out = case()
        assert out["status"] == "refused"
        (audit,) = audit_calls(fx)
        assert "BEGIN TRANSACTION" not in audit["sql"]
        assert pval(audit, "audit_result").startswith("refused:")
        assert pval(audit, "audit_window_state") == "human"


def test_audit_failure_does_not_mask_the_refusal(monkeypatch):
    def boom(sql, params, tool):
        raise RuntimeError("bq down")

    monkeypatch.setattr(fw, "_execute", boom)
    out = fw.reclassify_transaction("bad", "Cat", actor=ACTOR)
    assert out["status"] == "refused"
    assert "audit" in out


# ── the service gate ─────────────────────────────────────────────────────────


ENROLLED = "steven@example.com"


def _service() -> DoorService:
    return DoorService(policy=DoorPolicy(allowed_emails=frozenset({ENROLLED})))


def test_every_write_method_refuses_a_stranger(monkeypatch):
    def boom(sql, params, tool):
        raise AssertionError("a stranger's call must never reach BigQuery")

    monkeypatch.setattr(fw, "_execute", boom)
    service = _service()
    stranger = Identity(subject="google|2", email="nope@else.com", email_verified=True)
    governed = [
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
        assert call()["status"] == "forbidden"


def test_service_stamps_oauth_actor_onto_the_audit_row(monkeypatch):
    fx = fake(monkeypatch, [
        [{"checkpoint": "2026-09-07T10:00:00Z"}],
        WRITE_OK,
    ])
    service = _service()
    me = Identity(subject="google|1", email=ENROLLED, email_verified=True,
                  client_id="claude-ai")
    out = service.record_checkin_failed(me, "mercury token expired")
    assert out["status"] == "ok"
    (write,) = write_calls(fx)
    assert pval(write, "audit_identity") == ENROLLED
    assert pval(write, "audit_client_id") == "claude-ai"
    assert pval(write, "audit_window_state") == "human"
