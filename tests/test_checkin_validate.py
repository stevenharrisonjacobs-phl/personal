"""Offline tests for the spend check-in payload validator.

No GCP, no network — the validator is the sole integrity gate in front of
finance.checkin_reports (a durable, never-rebuilt table), so every refusal
path is pinned here. Run: python3 -m pytest tests/ -q
"""

from __future__ import annotations

import copy
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

from checkin_validate import canonical, validate  # noqa: E402


def payload(**overrides):
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
        "report_md": "## Check-in\nCard ****1234 ok. Total $284.12",
    }
    p.update(copy.deepcopy(overrides))
    return p


def errors_of(p):
    _, errors = validate(p)
    return errors


# -- happy path and canonicalization -----------------------------------------

def test_valid_payload_accepted_and_canonicalized():
    params, errors = validate(payload())
    assert errors == []
    assert params["window_start"] == "2026-09-07T10:00:00Z"
    assert params["consumed_checkpoint"] == "2026-09-07T10:00:00Z"


def test_mixed_precision_same_second_accepted():
    # The proven repro: sub-second run_ts one tick after a whole-second
    # window_end used to be refused by raw string comparison.
    p = payload(run_ts="2026-09-08T10:00:00.500Z", window_end="2026-09-08T10:00:00Z")
    assert errors_of(p) == []


def test_offset_form_equals_z_form():
    p = payload(consumed_checkpoint="2026-09-07T10:00:00+00:00")
    params, errors = validate(p)
    assert errors == []
    assert params["consumed_checkpoint"] == "2026-09-07T10:00:00Z"
    assert canonical("2026-09-07 10:00:00+0000") == "2026-09-07T10:00:00Z"


def test_first_run_without_checkpoint_accepted():
    p = payload()
    del p["consumed_checkpoint"]
    assert errors_of(p) == []


# -- window and contiguity refusals ------------------------------------------

def test_inverted_window_refused():
    assert any("window_end must be after" in e
               for e in errors_of(payload(window_end="2026-09-06T10:00:00Z")))


def test_run_ts_before_window_end_refused():
    assert any("run_ts must be at or after" in e
               for e in errors_of(payload(run_ts="2026-09-08T09:00:00Z")))


def test_window_start_not_equal_checkpoint_refused():
    errs = errors_of(payload(window_start="2026-09-07T12:00:00Z"))
    assert any("must equal the consumed checkpoint" in e for e in errs)


# -- source shape refusals ----------------------------------------------------

def test_empty_sources_refused():
    errs = errors_of(payload(sources={}, totals={}))
    assert any("sources.mirror missing" in e for e in errs)


def test_all_sources_failed_refused():
    p = payload()
    for s in p["sources"].values():
        s["status"], s["total"] = "failed", None
    for k in p["totals"]:
        p["totals"][k] = None
    assert any("no source succeeded" in e for e in errors_of(p))


def test_failed_source_with_total_refused():
    p = payload()
    p["sources"]["mercury"]["total"] = 5.0
    p["totals"]["mercury_cash"] = 5.0
    assert any("failed but carries a total" in e for e in errors_of(p))


# -- content refusals ----------------------------------------------------------

def test_digit_run_in_report_refused():
    p = payload()
    p["report_md"] += " acct 123456789012"
    assert any("report_md contains account-number-like" in e for e in errors_of(p))


def test_digit_run_in_source_note_refused():
    p = payload()
    p["sources"]["mercury"]["note"] = "card 4111111111111111 declined"
    assert any("sources contains account-number-like" in e for e in errors_of(p))


def test_masked_digits_pass():
    assert errors_of(payload()) == []  # ****1234 in the fixture report


# -- totals reconciliation -----------------------------------------------------

def test_totals_mismatch_refused():
    p = payload()
    p["totals"]["personal_cash"] = 999.0
    assert any("!= sources.mirror.total" in e for e in errors_of(p))


def test_presence_disagreement_refused():
    p = payload()
    p["totals"]["mercury_cash"] = 5.0
    assert any("disagree on presence" in e for e in errors_of(p))
