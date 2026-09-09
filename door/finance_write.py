"""Governed write tools for the personal door.

Each tool wraps one of the repo's guarded writers — scripts/checkin-write.sh
and the scripts/add-*.sh family — carrying their exact parameterized SQL and
validation. The door holds the only finance credential (KD5), so this module is
the ONLY write path from a conversation into the mirror.

Write discipline, in order of importance:
  * Append-only families (transaction/flow/category overrides): INSERT only.
    Latest-wins is enforced DOWNSTREAM — the consuming views rank by
    created_at DESC (sql/model.sql, sql/gold.sql) — so a correction is a new
    row, never a mutation. DELETE exists nowhere here.
  * Keyed lookup families (vendor_category_map, vendor_aliases, and both rule
    tables): MERGE upsert. The mapping/alias upserts are ported from the batch
    mode of their scripts (a pure append would fan duplicate alias_key rows
    through the un-deduped alias join in sql/gold.sql). The rule upserts key
    on rule_id, matching the replace semantics of add-rule.sh /
    add-vendor-rule.sh (DELETE+INSERT) without the DELETE — the consuming
    views rank rules by (priority, rule_id) with NO created_at dedup, so a
    re-asked rule_id must update its one row in place, never append a twin.
  * EVERY write attempt — accepted, no-op, refused — lands one row in
    finance.door_audit_log. Accepted writes bundle their data DML and audit
    INSERT into ONE BigQuery multi-statement transaction (single job), so they
    land or fail together. Validation refusals, which never reach DML, land a
    standalone audit INSERT; DoorService lands the same standalone INSERT
    (best effort, via audit_refusal) for authorization refusals that never
    reach this module.
  * The audit row carries enumerated statuses and row keys only — never
    read-back rows, amounts, memos, or free text. Digit runs >= 9 are scrubbed
    from args and results, EXCEPT inside 64-hex transaction keys, which are
    TO_HEX(SHA256) values and legitimately contain long digit runs.

Layering mirrors finance_native.py: everything above `_execute` is pure
(construction + validation, provable offline in tests/test_door_write.py).
`_execute` is the write touchpoint; `_job_outcome` is the only other one —
it exists because a write whose result timed out must be reconciled through
the JOB API, not through the query path whose outcome is in doubt.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import sys
import uuid
from dataclasses import dataclass
from typing import Any

from . import finance_native

# scripts/checkin_validate.py is the tested integrity gate for
# finance.checkin_reports (tests/test_checkin_validate.py); reuse the artifact,
# never fork it. In the repo this resolves to <root>/scripts; in the Cloud Run
# image the Dockerfile COPYs the file to /app/scripts so the same relative path
# holds.
_SCRIPTS_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"
)
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)
import checkin_validate  # noqa: E402

PROJECT = finance_native.PROJECT
FINANCE = finance_native.FINANCE
GOLD = finance_native.GOLD

AUDIT_TABLE = f"`{PROJECT}.{FINANCE}.door_audit_log`"
CHECKIN_TABLE = f"`{PROJECT}.{FINANCE}.checkin_reports`"

# Repo transaction keys are TO_HEX(SHA256(...)): exactly 64 lowercase hex.
TXN_KEY_RE = re.compile(r"^[0-9a-f]{64}$")
# Same account-number heuristic as checkin_validate; applied to every
# structured field EXCEPT transaction keys.
DIGIT_RUN = checkin_validate.DIGIT_RUN
# The flow_type vocabulary gold ACTUALLY understands: every value the
# classifier CASE in sql/gold.sql can emit, plus capital_proceeds, which only
# an override produces but the flow_* metric columns still score. A shape
# check is not enough here — gold.transactions COALESCEs the override
# straight into flow_type, and a value outside this set matches no metric
# CASE, so the transaction silently contributes to spending, income, refunds,
# transfers and investment activity alike: zero. A typo ('expnese') is the
# failure mode, and it is invisible. tests/test_door_write.py pins this set
# against sql/gold.sql so the two cannot drift apart.
FLOW_TYPES = frozenset({
    "adjustment",
    "cash_withdrawal",
    "capital_proceeds",
    "credit_card_payment",
    "earned_income",
    "expense",
    "internal_transfer",
    "investment_activity",
    "investment_income",
    "needs_review",
    "refund_reimbursement",
})
RULE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")

REASON_CAP = 300
FIELD_CAP = 300

# Enumerated replacements for a fail reason that violates the contract. The
# row still lands — failure recording must never itself fail — but with the
# generic code instead of the tainted text, and the audit row notes which.
REASON_CODES = {
    "digit-run": "door:reason-sanitized:digit-run",
    "multiline": "door:reason-sanitized:multiline",
    "overlong": "door:reason-sanitized:overlong",
}

GOLD_MATERIALIZATION_NOTE = (
    "Applied durably. gold.transactions materializes within the hour (hourly "
    "rebuild, or ./scripts/deploy.sh now); do not re-query gold.transactions "
    "to verify this write."
)


@dataclass(frozen=True)
class WriteActor:
    """Who is writing, stamped onto every audit row.

    Populated by DoorService: an OAuth identity stamps window_state 'human';
    a machine identity stamps 'human' while inside its grant's bounded
    America/New_York window and 'autonomous' otherwise.
    """

    identity: str
    client_id: str | None = None
    window_state: str = "human"


# ── pure: field validation ───────────────────────────────────────────────────


def validate_transaction_key(value: Any) -> str | None:
    if not isinstance(value, str) or not TXN_KEY_RE.match(value or ""):
        return (
            "transaction_key must be 64 lowercase hex characters "
            "(gold.transactions.transaction_key)"
        )
    return None


def field_error(
    name: str, value: Any, *, required: bool = True, cap: int = FIELD_CAP
) -> str | None:
    """Shape rules for every structured field that is NOT a transaction key:
    single line, capped, and no account-number-like digit runs."""
    if value is None:
        value = ""
    if not isinstance(value, str):
        return f"{name} must be a string"
    if required and not value.strip():
        return f"{name} is required"
    if len(value) > cap:
        return f"{name} is over the {cap}-character cap"
    if "\n" in value or "\r" in value:
        return f"{name} must be a single line"
    if DIGIT_RUN.search(value):
        return f"{name} contains an account-number-like digit run"
    return None


def sanitize_fail_reason(reason: Any) -> tuple[str, str | None]:
    """Return (reason to land, sanitization code or None). Never raises."""
    text = reason if isinstance(reason, str) else ""
    if not text.strip():
        return "unspecified", None  # the bash twin's default
    if DIGIT_RUN.search(text):
        return REASON_CODES["digit-run"], "digit-run"
    if "\n" in text or "\r" in text:
        return REASON_CODES["multiline"], "multiline"
    if len(text) > REASON_CAP:
        return REASON_CODES["overlong"], "overlong"
    return text, None


def sanitize_echo(value: Any) -> Any:
    """Shape-gate a RAW, unvalidated payload field before echoing it into
    audit args: violating values are replaced with an enumerated placeholder
    (or truncated to the field cap), never landed verbatim — the same
    replace-not-refuse pattern as sanitize_fail_reason. scrub_audit_value
    would catch digit runs anyway; this also keeps non-string, multiline, and
    overlong junk out of the audit log."""
    if value is None:
        return None
    if not isinstance(value, str):
        return f"invalid:{type(value).__name__}"
    if DIGIT_RUN.search(value):
        return "invalid:digit-run"
    if "\n" in value or "\r" in value:
        return "invalid:multiline"
    if len(value) > FIELD_CAP:
        return value[:FIELD_CAP]
    return value


# ── pure: audit construction ─────────────────────────────────────────────────


def _scrub_text(text: str) -> str:
    return DIGIT_RUN.sub("[digits-redacted]", text)


def scrub_audit_value(value: Any) -> Any:
    """Recursively strip digit runs from anything headed for the audit log,
    exempting values that are exactly a 64-hex transaction key."""
    if isinstance(value, str):
        return value if TXN_KEY_RE.match(value) else _scrub_text(value)
    if isinstance(value, dict):
        return {key: scrub_audit_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [scrub_audit_value(item) for item in value]
    return value


def audit_args_json(fields: dict) -> str:
    return json.dumps(scrub_audit_value(fields), default=str, sort_keys=True)


def _audit_params(actor: WriteActor, tool: str, args_json: str) -> list[tuple]:
    return [
        ("audit_identity", "STRING", actor.identity),
        ("audit_client_id", "STRING", actor.client_id),
        ("audit_window_state", "STRING", actor.window_state),
        ("audit_tool", "STRING", tool),
        ("audit_args", "STRING", args_json),
    ]


def _audit_insert_sql(result_expr: str) -> str:
    return (
        f"INSERT INTO {AUDIT_TABLE}\n"
        "  (ts, identity, client_id, window_state, tool, args, result)\n"
        "VALUES (CURRENT_TIMESTAMP(), @audit_identity, @audit_client_id,\n"
        "        @audit_window_state, @audit_tool, PARSE_JSON(@audit_args),\n"
        f"        {result_expr})"
    )


def build_audit_only(
    tool: str, actor: WriteActor, args_json: str, result: str
) -> tuple[str, list[tuple]]:
    """A refusal's audit row: one plain INSERT, no transaction needed."""
    sql = _audit_insert_sql("@audit_result")
    params = _audit_params(actor, tool, args_json)
    params.append(("audit_result", "STRING", result))
    return sql, params


def build_transactional(
    *,
    tool: str,
    actor: WriteActor,
    args_json: str,
    dml_sql: str,
    dml_params: list[tuple],
    row_key: str,
    pre_sql: str = "",
    sanitized: str | None = None,
) -> tuple[str, list[tuple]]:
    """One BigQuery job: data DML + audit INSERT inside one transaction.

    @@row_count after the DML distinguishes 'ok' from 'no-op' (a MERGE whose
    WHEN NOT MATCHED did not fire), both in the audit row and in the job's
    final SELECT, which is what the caller reads back.
    """
    note = f" sanitized={sanitized}" if sanitized else ""
    statements = ["DECLARE affected INT64 DEFAULT 0"]
    if pre_sql:
        statements.append(pre_sql)
    statements += [
        "BEGIN TRANSACTION",
        dml_sql,
        "SET affected = @@row_count",
        _audit_insert_sql("IF(affected > 0, @audit_result_ok, @audit_result_noop)"),
        "COMMIT TRANSACTION",
        "SELECT IF(affected > 0, 'ok', 'no-op') AS write_result",
    ]
    params = list(dml_params) + _audit_params(actor, tool, args_json)
    params += [
        ("audit_result_ok", "STRING", f"ok key={row_key}{note}"),
        ("audit_result_noop", "STRING", f"no-op key={row_key}{note}"),
    ]
    return ";\n".join(statements) + ";", params


# ── pure: the ported DML, one builder per guarded writer ─────────────────────


def _checkin_merge_dml() -> str:
    # Exact port of scripts/checkin-write.sh success mode: match ONLY
    # status='success' rows on window_start, insert-if-absent, never update —
    # a double fire lands zero or one success row.
    return (
        f"MERGE {CHECKIN_TABLE} T\n"
        "USING (SELECT @window_start AS window_start) S\n"
        "ON T.window_start = S.window_start AND T.status = 'success'\n"
        "WHEN NOT MATCHED THEN INSERT\n"
        "  (run_ts, consumed_checkpoint, window_start, window_end, status,\n"
        "   sources, totals, report_md)\n"
        "VALUES (@run_ts, SAFE_CAST(NULLIF(@consumed_checkpoint, '') AS TIMESTAMP),\n"
        "        @window_start, @window_end,\n"
        "        'success', PARSE_JSON(@sources), PARSE_JSON(@totals), @report_md)"
    )


def _checkin_failed_dml() -> str:
    # Exact port of the failed mode: a zero-length window (@window_start twice)
    # that can never advance any checkpoint.
    return (
        f"INSERT INTO {CHECKIN_TABLE}\n"
        "  (run_ts, consumed_checkpoint, window_start, window_end, status, fail_reason)\n"
        "VALUES (@run_ts, SAFE_CAST(NULLIF(@consumed_checkpoint, '') AS TIMESTAMP),\n"
        "        @window_start, @window_start, 'failed', @reason)"
    )


def _reclassify_dml() -> str:
    # scripts/add-override.sh — pure append into finance.transaction_overrides.
    return (
        f"INSERT INTO `{PROJECT}.{FINANCE}.transaction_overrides`\n"
        "  (transaction_key, category, notes, created_at)\n"
        "VALUES (@transaction_key, @category, NULLIF(@notes, ''), CURRENT_TIMESTAMP())"
    )


def _vendor_override_dml() -> str:
    # scripts/add-vendor-override.sh — pure append.
    return (
        f"INSERT INTO `{PROJECT}.{GOLD}.transaction_vendor_overrides`\n"
        "  (transaction_key, vendor_name, notes, created_at)\n"
        "VALUES (@transaction_key, @vendor_name, NULLIF(@notes, ''), CURRENT_TIMESTAMP())"
    )


def _flow_override_dml() -> str:
    # scripts/add-flow-override.sh — pure append.
    return (
        f"INSERT INTO `{PROJECT}.{GOLD}.transaction_flow_overrides`\n"
        "  (transaction_key, flow_type, notes, created_at)\n"
        "VALUES (@transaction_key, @flow_type, NULLIF(@notes, ''), CURRENT_TIMESTAMP())"
    )


def _mapping_dml() -> str:
    # scripts/add-vendor-category.sh batch mode, for one row: MERGE upsert on
    # vendor_name (the script's single mode DELETE+INSERTs; the door never
    # deletes, and the MERGE has the same effect for the downstream
    # latest-wins read in sql/gold.sql).
    return (
        f"MERGE `{PROJECT}.{GOLD}.vendor_category_map` AS t\n"
        "USING (SELECT @vendor_name AS vendor_name, @category_id AS category_id,\n"
        "              @notes AS notes) AS s\n"
        "ON t.vendor_name = s.vendor_name\n"
        "WHEN MATCHED THEN UPDATE SET\n"
        "  category_id = s.category_id,\n"
        "  notes       = NULLIF(s.notes, ''),\n"
        "  enabled     = TRUE\n"
        "WHEN NOT MATCHED THEN INSERT (vendor_name, category_id, notes, enabled, created_at)\n"
        "  VALUES (s.vendor_name, s.category_id, NULLIF(s.notes, ''), TRUE, CURRENT_TIMESTAMP())"
    )


def _alias_dml() -> str:
    # scripts/add-vendor-alias.sh batch mode, for one row: MERGE on the
    # normalized alias_key. An append here would fan duplicate alias_key rows
    # through the un-deduped alias join in sql/gold.sql (~line 227).
    return (
        f"MERGE `{PROJECT}.{GOLD}.vendor_aliases` AS t\n"
        "USING (\n"
        "  SELECT\n"
        "    REGEXP_REPLACE(LOWER(@alias_name), r'[^a-z0-9]+', '') AS alias_key,\n"
        "    @alias_name AS alias_name,\n"
        "    @canonical_vendor_name AS canonical_vendor_name,\n"
        "    @notes AS notes\n"
        ") AS s\n"
        "ON t.alias_key = s.alias_key\n"
        "WHEN MATCHED THEN UPDATE SET\n"
        "  alias_name            = s.alias_name,\n"
        "  canonical_vendor_name = s.canonical_vendor_name,\n"
        "  notes                 = NULLIF(s.notes, ''),\n"
        "  enabled               = TRUE\n"
        "WHEN NOT MATCHED THEN INSERT\n"
        "  (alias_key, alias_name, canonical_vendor_name, notes, enabled, created_at)\n"
        "  VALUES (s.alias_key, s.alias_name, s.canonical_vendor_name,\n"
        "          NULLIF(s.notes, ''), TRUE, CURRENT_TIMESTAMP())"
    )


def _classification_rule_dml() -> str:
    # scripts/add-rule.sh replaces by rule_id (DELETE+INSERT); the door keeps
    # those replace semantics without DELETE: a keyed MERGE upsert on rule_id,
    # same pattern as _mapping_dml/_alias_dml, with the script's fixed
    # direction='expense' and enabled=TRUE. A pure append would leave a
    # re-asked rule_id as two enabled rows, and the consuming view ranks by
    # (priority, rule_id) with no created_at dedup — the old rule would win
    # ties instead of the correction.
    return (
        f"MERGE `{PROJECT}.{FINANCE}.classification_rules` AS t\n"
        "USING (SELECT @rule_id AS rule_id, @priority AS priority,\n"
        "              @description_regex AS description_regex,\n"
        "              @category AS category, @subcategory AS subcategory) AS s\n"
        "ON t.rule_id = s.rule_id\n"
        "WHEN MATCHED THEN UPDATE SET\n"
        "  priority          = s.priority,\n"
        "  description_regex = s.description_regex,\n"
        "  category          = s.category,\n"
        "  subcategory       = NULLIF(s.subcategory, ''),\n"
        "  enabled           = TRUE\n"
        "WHEN NOT MATCHED THEN INSERT\n"
        "  (rule_id, priority, description_regex, direction, category, subcategory,\n"
        "   enabled, created_at)\n"
        "  VALUES (s.rule_id, s.priority, s.description_regex, 'expense', s.category,\n"
        "          NULLIF(s.subcategory, ''), TRUE, CURRENT_TIMESTAMP())"
    )


def _vendor_rule_dml() -> str:
    # scripts/add-vendor-rule.sh replaces by rule_id (DELETE+INSERT); same
    # replace semantics here via a keyed MERGE upsert on rule_id, no DELETE
    # (see _classification_rule_dml for why an append would misrank re-asks).
    return (
        f"MERGE `{PROJECT}.{GOLD}.vendor_rules` AS t\n"
        "USING (SELECT @rule_id AS rule_id, @priority AS priority,\n"
        "              @description_regex AS description_regex,\n"
        "              @vendor_name AS vendor_name, @notes AS notes) AS s\n"
        "ON t.rule_id = s.rule_id\n"
        "WHEN MATCHED THEN UPDATE SET\n"
        "  priority          = s.priority,\n"
        "  description_regex = s.description_regex,\n"
        "  vendor_name       = s.vendor_name,\n"
        "  notes             = NULLIF(s.notes, ''),\n"
        "  enabled           = TRUE\n"
        "WHEN NOT MATCHED THEN INSERT\n"
        "  (rule_id, priority, description_regex, vendor_name, notes, enabled, created_at)\n"
        "  VALUES (s.rule_id, s.priority, s.description_regex, s.vendor_name,\n"
        "          NULLIF(s.notes, ''), TRUE, CURRENT_TIMESTAMP())"
    )


# add-vendor-rule.sh's regex validity probe: an invalid RE2 pattern fails this
# statement, so the job dies BEFORE the transaction opens and no half-formed
# rule can brick the consuming view at read time. Applied to both rule tools —
# add-rule.sh lacks it, but a bad regex in classification_rules would error
# every query on finance.v_transactions_classified.
_REGEX_GUARD = "SELECT IF(NOT REGEXP_CONTAINS('', @description_regex), TRUE, TRUE)"


# ── execution: the only BigQuery touchpoint ──────────────────────────────────

# A stuck backend must surface as a bounded, honest outcome rather than hang
# the tool while a half-open transaction holds locks: bound both the submission
# RPC and the wait for the job's result. Timing out is NOT failing (see
# JobIndeterminate), so these bounds cost accuracy, never correctness.
JOB_SUBMIT_TIMEOUT = 60  # seconds for client.query() to submit the job
JOB_RESULT_TIMEOUT = 240  # seconds for job.result() to finish
JOB_LOOKUP_TIMEOUT = 30  # seconds for the reconciling jobs.get / result read


class JobIndeterminate(Exception):
    """We stopped waiting on a write job whose outcome is genuinely unknown.

    `job.result(timeout=...)` expiring means only that the CLIENT gave up; the
    transaction may commit a moment later. Reporting that as a rolled-back
    write is the dangerous lie — it invites a retry that appends a second
    override row or lands a duplicate check-in. Carries the job id so the
    outcome can be reconciled against BigQuery's own record of the job.
    """

    def __init__(self, message: str, *, job_id: str | None = None):
        super().__init__(message)
        self.job_id = job_id


def _job_id(tool: str) -> str:
    """A client-side job id, so a job that outruns our wait stays nameable.

    Without one, BigQuery assigns the id server-side and a submit RPC that
    times out leaves an unnameable — and therefore unreconcilable — job.
    """
    return f"door-{re.sub(r'[^a-z0-9_-]', '-', tool.lower())[:40]}-{uuid.uuid4().hex}"


def _execute(sql: str, params: list[tuple], tool: str) -> list[dict]:
    """Run one job, return the last statement's rows as JSON-safe dicts.

    Tests replace this wholesale; nothing above it touches GCP. Multi-statement
    jobs surface the FINAL statement's result set, which is why every write
    script ends with `SELECT ... AS write_result`.

    Raises JobIndeterminate — never a plain error — when a timeout leaves the
    job's fate unknown. Every other failure is a real failure.
    """
    from concurrent.futures import TimeoutError as _WaitTimeout

    from google.cloud import bigquery

    client = finance_native._bq()
    job_id = _job_id(tool)
    try:
        job = client.query(
            sql,
            job_config=bigquery.QueryJobConfig(
                query_parameters=[
                    bigquery.ScalarQueryParameter(name, type_, value)
                    for name, type_, value in params
                ],
                maximum_bytes_billed=finance_native.MAX_BYTES_BILLED,
                labels={"tool": re.sub(r"[^a-z0-9_-]", "-", tool.lower())[:60]},
            ),
            job_id=job_id,
            timeout=JOB_SUBMIT_TIMEOUT,
        )
    except _WaitTimeout as exc:
        # The submit RPC may still have created the job server-side.
        raise JobIndeterminate(
            f"submit did not answer inside {JOB_SUBMIT_TIMEOUT}s", job_id=job_id
        ) from exc
    try:
        rows = list(job.result(timeout=JOB_RESULT_TIMEOUT))
    except _WaitTimeout as exc:
        # Best effort: stop the job so it cannot sit on locks. A cancel that
        # arrives after COMMIT is a no-op, which is exactly why cancelling is
        # not the same as knowing the outcome.
        try:
            job.cancel()
        except Exception:
            pass
        raise JobIndeterminate(
            f"job did not finish inside {JOB_RESULT_TIMEOUT}s",
            job_id=job.job_id or job_id,
        ) from exc
    return [
        finance_native._redact_row(
            {key: finance_native._json_value(value) for key, value in dict(row).items()}
        )
        for row in rows
    ]


def _job_outcome(job_id: str) -> dict:
    """Ask BigQuery what actually became of a job we stopped waiting on.

    The second (and last) BigQuery touchpoint; tests replace it alongside
    `_execute`. It deliberately goes through the JOB API rather than re-running
    or re-reading anything: the question is whether OUR transaction committed,
    and only the job's own record answers that without ambiguity.

    -> {"state": "committed"|"failed"|"running"|"unknown",
        "write_result": str|None, "error": str|None}
    """
    try:
        client = finance_native._bq()
        job = client.get_job(job_id, timeout=JOB_LOOKUP_TIMEOUT)
        if job.state != "DONE":
            return {"state": "running", "write_result": None, "error": None}
        if job.error_result:
            return {"state": "failed", "write_result": None,
                    "error": str(job.error_result.get("message", ""))[:400]}
        # DONE and clean: the transaction committed. The final statement's
        # SELECT names ok vs no-op, and it is already materialized.
        rows = list(job.result(timeout=JOB_LOOKUP_TIMEOUT))
        write_result = (dict(rows[0]).get("write_result") if rows else None) or "ok"
        return {"state": "committed", "write_result": str(write_result), "error": None}
    except Exception:
        return {"state": "unknown", "write_result": None, "error": None}


# ── shared plumbing ──────────────────────────────────────────────────────────


def _refuse(
    tool: str,
    actor: WriteActor,
    args: dict,
    code: str,
    *,
    error: str,
    row_key: str | None = None,
    extra: dict | None = None,
) -> dict:
    """Land the refusal's audit row (best effort), then explain the refusal."""
    result = f"refused:{code}" + (f" key={row_key}" if row_key else "")
    sql, params = build_audit_only(tool, actor, audit_args_json(args), result)
    try:
        _execute(sql, params, tool)
        audit = "logged"
    except Exception as exc:  # the audit failing must not mask the refusal
        audit = f"audit-write-failed: {_scrub_text(str(exc)[:200])}"
    out = {"status": "refused", "reason": code, "error": error, "audit": audit}
    if extra:
        out.update(extra)
    return out


def audit_refusal(
    actor: WriteActor, tool: str, code: str, args: dict | None = None
) -> None:
    """Best-effort standalone audit row for a write attempt refused BEFORE the
    write runtime runs (DoorService authorization refusals: forbidden tool,
    out-of-window, unknown machine identity). One plain INSERT reusing the
    refusal audit construction and scrubbing; its own failure is swallowed so
    it can never mask or reshape the refusal it records."""
    try:
        sql, params = build_audit_only(tool, actor, audit_args_json(args or {}), code)
        _execute(sql, params, tool)
    except Exception:
        pass


def _run_write(
    tool: str,
    actor: WriteActor,
    args: dict,
    dml_sql: str,
    dml_params: list[tuple],
    row_key: str,
    *,
    pre_sql: str = "",
    sanitized: str | None = None,
) -> dict:
    sql, params = build_transactional(
        tool=tool,
        actor=actor,
        args_json=audit_args_json(args),
        dml_sql=dml_sql,
        dml_params=dml_params,
        row_key=row_key,
        pre_sql=pre_sql,
        sanitized=sanitized,
    )
    try:
        rows = _execute(sql, params, tool)
    except JobIndeterminate as exc:
        return _reconcile(tool, actor, args, row_key, exc)
    except Exception as exc:
        # The transaction rolled back — data AND audit — so record the failed
        # attempt standalone, then report it.
        out = _refuse(tool, actor, args, "job-failed",
                      error=_scrub_text(str(exc)[:400]), row_key=row_key)
        out["status"] = "error"
        return out
    write_result = (rows[0].get("write_result") if rows else None) or "ok"
    return {"status": write_result}


def _reconcile(
    tool: str, actor: WriteActor, args: dict, row_key: str, exc: JobIndeterminate
) -> dict:
    """Resolve a write whose wait timed out, by asking what the job did.

    Three honest answers, and 'error' is only ever one of them:
      * the job failed      -> the transaction rolled back; the existing
                               job-failed path, unchanged
      * the job committed    -> the write landed AFTER we stopped waiting. Its
                               audit row committed in the same transaction, so
                               no standalone audit row is added here.
      * still running / unknowable -> status 'indeterminate'. NOT an error: a
                               retry could duplicate an append-only override
                               or a check-in, so the caller is told to
                               reconcile rather than re-fire.
    """
    detail = _scrub_text(str(exc)[:300])
    outcome = _job_outcome(exc.job_id) if exc.job_id else {"state": "unknown"}
    state = outcome.get("state")

    if state == "failed":
        out = _refuse(
            tool, actor, args, "job-failed",
            error=_scrub_text(f"{detail}; the job then failed: {outcome.get('error') or ''}"[:400]),
            row_key=row_key,
        )
        out["status"] = "error"
        out["job_id"] = exc.job_id
        return out

    if state == "committed":
        return {
            "status": outcome.get("write_result") or "ok",
            "warning": "completed_after_timeout",
            "job_id": exc.job_id,
            "note": (
                f"the wait timed out ({detail}) but job {exc.job_id} committed; "
                "the row and its audit row are durable — do not retry"
            ),
        }

    # Neither committed nor failed as far as we can tell. Record the attempt
    # standalone — the transactional audit row lands only if the job commits,
    # so without this the trail would show nothing at all.
    audit = "logged"
    try:
        sql, params = build_audit_only(
            tool, actor, audit_args_json(args),
            f"indeterminate key={row_key} job={exc.job_id or 'unknown'}",
        )
        _execute(sql, params, tool)
    except Exception as audit_exc:
        audit = f"audit-write-failed: {_scrub_text(str(audit_exc)[:200])}"
    return {
        "status": "indeterminate",
        "reason": "job-outcome-unknown",
        "job_id": exc.job_id,
        "audit": audit,
        "error": detail,
        "note": (
            "the write may or may not have landed: the wait expired and the "
            f"job's outcome could not be established ({state}). Do NOT retry "
            "blindly — read the target row back (or check the job in BigQuery) "
            "and re-issue only if nothing landed."
        ),
    }


def _read(sql: str, params: list[tuple], tool: str) -> list[dict] | None:
    """Internal bounded read-back; None means the read itself failed."""
    try:
        return _execute(sql, params, tool)
    except Exception:
        return None


def _latest_row(
    tool: str, table: str, columns: str, key_col: str, key_val: str
) -> dict | None:
    """Read back the row a write just landed: latest by created_at for the key.
    None means the row is absent or the read-back itself failed."""
    rows = _read(
        f"SELECT {columns}\n"
        f"FROM {table}\n"
        f"WHERE {key_col} = @{key_col}\n"
        "ORDER BY created_at DESC LIMIT 1",
        [(key_col, "STRING", key_val)],
        tool,
    )
    return rows[0] if rows else None


def _now_utc() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _resolve_checkpoint(tool: str) -> str:
    # Port of checkin-write.sh resolve_checkpoint().
    rows = _execute(
        "SELECT IFNULL(FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', MAX(window_end)),"
        " 'none') AS checkpoint\n"
        f"FROM {CHECKIN_TABLE} WHERE status = 'success'",
        [],
        tool,
    )
    return str(rows[0]["checkpoint"]) if rows else "none"


# ── tools: the check-in report writer ────────────────────────────────────────


def record_checkin(payload: dict, *, actor: WriteActor) -> dict:
    tool = "record_checkin"
    if not isinstance(payload, dict):
        return _refuse(tool, actor, {"payload_type": type(payload).__name__},
                       "invalid-payload", error="payload must be an object")
    echoed = {
        field: sanitize_echo(payload.get(field))
        for field in ("run_ts", "window_start", "window_end", "consumed_checkpoint")
    }
    try:
        params, errors = checkin_validate.validate(payload)
    except Exception as exc:
        # checkin_validate.TS_RE accepts calendar-invalid timestamps
        # (2026-02-30...); parse_ts then raises inside validate(). Refuse
        # structurally — with the standard refusal audit row — rather than
        # escaping as an unstructured tool crash. Guard HERE only: the shared
        # validator is also the laptop writer's, so it stays unforked.
        err_line = _scrub_text(" ".join(str(exc).split())[:REASON_CAP])
        return _refuse(tool, actor, echoed, "invalid-payload",
                       error=f"payload failed validation: {err_line}")
    if errors:
        detail = [_scrub_text(e) for e in errors]
        args = {**echoed, "error_count": len(errors)}
        return _refuse(tool, actor, args, "invalid-payload",
                       error="payload failed validation", extra={"detail": detail})

    args = {k: params[k] for k in
            ("run_ts", "consumed_checkpoint", "window_start", "window_end")}

    # Re-resolve the checkpoint immediately before the write; abort loudly if
    # another run landed since the payload was composed.
    try:
        live = _resolve_checkpoint(tool)
    except Exception as exc:
        return {"status": "error",
                "error": f"could not resolve checkpoint: {_scrub_text(str(exc)[:300])}"}
    if live != params["consumed_checkpoint"]:
        return _refuse(
            tool, actor, {**args, "live_checkpoint": live}, "checkpoint-moved",
            error=(f"payload consumed checkpoint {params['consumed_checkpoint']} "
                   f"but the live checkpoint is {live}; recompose against the "
                   "live checkpoint"),
            row_key=f"window_start={params['window_start']}",
        )

    ckpt_param = "" if params["consumed_checkpoint"] == "none" else params["consumed_checkpoint"]
    dml_params = [
        ("run_ts", "TIMESTAMP", params["run_ts"]),
        ("consumed_checkpoint", "STRING", ckpt_param),
        ("window_start", "TIMESTAMP", params["window_start"]),
        ("window_end", "TIMESTAMP", params["window_end"]),
        ("sources", "STRING", params["sources"]),
        ("totals", "STRING", params["totals"]),
        ("report_md", "STRING", params["report_md"]),
    ]
    out = _run_write(tool, actor, args, _checkin_merge_dml(), dml_params,
                     f"window_start={params['window_start']}")
    if out["status"] not in ("ok", "no-op"):
        return out

    # Completion signal = the durable artifact, not the job's exit status.
    confirm = _read(
        "SELECT run_ts, consumed_checkpoint, window_start, window_end, status\n"
        f"FROM {CHECKIN_TABLE}\n"
        "WHERE window_start = @window_start AND status = 'success'\n"
        "LIMIT 1",
        [("window_start", "TIMESTAMP", params["window_start"])],
        tool,
    )
    if confirm is None:
        # The MERGE+audit transaction COMMITTED; only the post-write
        # confirmation read failed. Conflating that with row absence would
        # invite a retry after durable success — report the committed result
        # with a warning instead.
        out["warning"] = "confirmation_unavailable"
        out["note"] = (
            "the write committed but the post-write confirmation read failed "
            "transiently; the row is durable — do not retry"
        )
        return out
    if not confirm:
        return {"status": "error",
                "error": "row did not land (post-write confirmation found nothing)"}
    out["row"] = confirm[0]
    out["note"] = (
        "duplicate fire: a success row already covered this window; nothing changed"
        if out["status"] == "no-op"
        else "success row landed and confirmed"
    )
    return out


def record_checkin_failed(reason: str, *, actor: WriteActor) -> dict:
    """Failure recording must never itself fail: sanitize rather than refuse,
    fall back rather than abort."""
    tool = "record_checkin_failed"
    landed_reason, code = sanitize_fail_reason(reason)

    try:
        checkpoint = _resolve_checkpoint(tool)
    except Exception:
        checkpoint = "none"  # still land the row, anchored at now
    if checkpoint == "none":
        window_start, ckpt_param = _now_utc(), ""
    else:
        window_start, ckpt_param = checkpoint, checkpoint
    now = _now_utc()

    args = {
        "window_start": window_start,
        "consumed_checkpoint": ckpt_param or "none",
        "reason_code": code or "verbatim",
    }
    dml_params = [
        ("run_ts", "TIMESTAMP", now),
        ("consumed_checkpoint", "STRING", ckpt_param),
        ("window_start", "TIMESTAMP", window_start),
        ("reason", "STRING", landed_reason),
    ]
    out = _run_write(tool, actor, args, _checkin_failed_dml(), dml_params,
                     f"window_start={window_start}", sanitized=code)
    if out["status"] not in ("ok", "no-op"):
        return out
    out["row"] = {
        "run_ts": now,
        "window_start": window_start,
        "window_end": window_start,
        "status": "failed",
        "fail_reason": landed_reason,
    }
    if code:
        out["sanitized"] = code
        out["note"] = (
            "the provided reason violated the content contract "
            f"({code}) and was replaced with an enumerated code; the row landed"
        )
    return out


# ── tools: classification family ─────────────────────────────────────────────


def _unknown_transaction(
    tool: str, actor: WriteActor, args: dict, transaction_key: str
) -> dict | None:
    """Validate-first, mirroring add-vendor-category.sh: None when the key
    names a real transaction, otherwise the response to return.

    Every override family needs this, not just reclassify. The bash twins
    (add-override.sh, add-flow-override.sh) lack the check, and an override on
    a key that matches nothing is an orphan row: it lands, it reports success,
    it proves nothing, and it classifies nothing — forever, since the override
    tables are append-only and the join simply never matches.
    """
    exists = _read(
        f"SELECT transaction_key FROM `{PROJECT}.{FINANCE}.v_transactions_classified`\n"
        "WHERE transaction_key = @transaction_key LIMIT 1",
        [("transaction_key", "STRING", transaction_key)],
        tool,
    )
    if exists is None:
        return {"status": "error", "error": "could not verify the transaction exists"}
    if not exists:
        return _refuse(
            tool, actor, args, "unknown-transaction",
            error="no transaction with that key exists in the mirror",
            row_key=f"transaction_key={transaction_key}",
        )
    return None


def reclassify_transaction(
    transaction_key: str, category: str, notes: str = "", *, actor: WriteActor
) -> dict:
    tool = "reclassify_transaction"
    args = {"transaction_key": transaction_key, "category": category}

    err = validate_transaction_key(transaction_key)
    if err:
        return _refuse(tool, actor, args, "invalid-transaction-key", error=err)
    err = field_error("category", category) or field_error("notes", notes, required=False)
    if err:
        return _refuse(tool, actor, args, "invalid-field", error=err,
                       row_key=f"transaction_key={transaction_key}")

    missing = _unknown_transaction(tool, actor, args, transaction_key)
    if missing:
        return missing

    dml_params = [
        ("transaction_key", "STRING", transaction_key),
        ("category", "STRING", category),
        ("notes", "STRING", notes or ""),
    ]
    out = _run_write(tool, actor, args, _reclassify_dml(), dml_params,
                     f"transaction_key={transaction_key}")
    if out["status"] not in ("ok", "no-op"):
        return out

    row = _latest_row(
        tool, f"`{PROJECT}.{FINANCE}.transaction_overrides`",
        "transaction_key, category, notes, created_at",
        "transaction_key", transaction_key,
    )
    proof = _read(
        "SELECT transaction_key, category, subcategory, classification_source\n"
        f"FROM `{PROJECT}.{FINANCE}.v_transactions_classified`\n"
        "WHERE transaction_key = @transaction_key LIMIT 1",
        [("transaction_key", "STRING", transaction_key)],
        tool,
    )
    out["row"] = row
    out["classification_proof"] = proof[0] if proof else None
    out["semantics"] = (
        "append-only: the latest override by created_at wins in "
        "finance.v_transactions_classified; earlier rows remain as history"
    )
    out["materialization"] = GOLD_MATERIALIZATION_NOTE
    return out


def set_vendor_override(
    transaction_key: str, vendor_name: str, notes: str = "", *, actor: WriteActor
) -> dict:
    tool = "set_vendor_override"
    args = {"transaction_key": transaction_key, "vendor_name": vendor_name}

    err = validate_transaction_key(transaction_key)
    if err:
        return _refuse(tool, actor, args, "invalid-transaction-key", error=err)
    err = field_error("vendor_name", vendor_name) or field_error("notes", notes, required=False)
    if err:
        return _refuse(tool, actor, args, "invalid-field", error=err,
                       row_key=f"transaction_key={transaction_key}")
    missing = _unknown_transaction(tool, actor, args, transaction_key)
    if missing:
        return missing

    dml_params = [
        ("transaction_key", "STRING", transaction_key),
        ("vendor_name", "STRING", vendor_name),
        ("notes", "STRING", notes or ""),
    ]
    out = _run_write(tool, actor, args, _vendor_override_dml(), dml_params,
                     f"transaction_key={transaction_key}")
    if out["status"] not in ("ok", "no-op"):
        return out
    out["row"] = _latest_row(
        tool, f"`{PROJECT}.{GOLD}.transaction_vendor_overrides`",
        "transaction_key, vendor_name, notes, created_at",
        "transaction_key", transaction_key,
    )
    out["semantics"] = "append-only: the latest override by created_at wins in gold"
    out["materialization"] = GOLD_MATERIALIZATION_NOTE
    return out


def set_flow_override(
    transaction_key: str, flow_type: str, notes: str = "", *, actor: WriteActor
) -> dict:
    tool = "set_flow_override"
    args = {"transaction_key": transaction_key, "flow_type": flow_type}

    err = validate_transaction_key(transaction_key)
    if err:
        return _refuse(tool, actor, args, "invalid-transaction-key", error=err)
    if not isinstance(flow_type, str) or flow_type not in FLOW_TYPES:
        return _refuse(
            tool, actor, args, "invalid-flow-type",
            error=("flow_type must be one of the values gold understands: "
                   + ", ".join(sorted(FLOW_TYPES))),
            row_key=f"transaction_key={transaction_key}",
        )
    err = field_error("notes", notes, required=False)
    if err:
        return _refuse(tool, actor, args, "invalid-field", error=err,
                       row_key=f"transaction_key={transaction_key}")
    missing = _unknown_transaction(tool, actor, args, transaction_key)
    if missing:
        return missing

    dml_params = [
        ("transaction_key", "STRING", transaction_key),
        ("flow_type", "STRING", flow_type),
        ("notes", "STRING", notes or ""),
    ]
    out = _run_write(tool, actor, args, _flow_override_dml(), dml_params,
                     f"transaction_key={transaction_key}")
    if out["status"] not in ("ok", "no-op"):
        return out
    out["row"] = _latest_row(
        tool, f"`{PROJECT}.{GOLD}.transaction_flow_overrides`",
        "transaction_key, flow_type, notes, created_at",
        "transaction_key", transaction_key,
    )
    out["semantics"] = "append-only: the latest override by created_at wins in gold"
    out["materialization"] = GOLD_MATERIALIZATION_NOTE
    return out


def add_vendor_mapping(
    vendor_name: str, category_id: str, notes: str = "", *, actor: WriteActor
) -> dict:
    tool = "add_vendor_mapping"
    args = {"vendor_name": vendor_name, "category_id": category_id}

    err = (field_error("vendor_name", vendor_name)
           or field_error("category_id", category_id)
           or field_error("notes", notes, required=False))
    if err:
        return _refuse(tool, actor, args, "invalid-field", error=err)

    # A typo'd category_id inserts a row that silently classifies nothing, so
    # validate against the live typology before writing anything (the port of
    # add-vendor-category.sh's valid_ids gate). No LIMIT, matching the bash
    # twin, which reads ALL active category_ids — the categories table is
    # small and the read is already bounded by the door's byte cap.
    ids = _read(
        f"SELECT category_id FROM `{PROJECT}.{GOLD}.categories`\n"
        "WHERE active ORDER BY category_id",
        [],
        tool,
    )
    if ids is None:
        return {"status": "error", "error": "could not read the live category typology"}
    valid = [row["category_id"] for row in ids]
    if category_id not in valid:
        return _refuse(
            tool, actor, args, "unknown-category",
            error=f"unknown category_id: {category_id}",
            row_key=f"vendor_name={_scrub_text(vendor_name)}",
            extra={"valid_category_ids": valid},
        )

    dml_params = [
        ("vendor_name", "STRING", vendor_name),
        ("category_id", "STRING", category_id),
        ("notes", "STRING", notes or ""),
    ]
    out = _run_write(tool, actor, args, _mapping_dml(), dml_params,
                     f"vendor_name={_scrub_text(vendor_name)}")
    if out["status"] not in ("ok", "no-op"):
        return out
    out["row"] = _latest_row(
        tool, f"`{PROJECT}.{GOLD}.vendor_category_map`",
        "vendor_name, category_id, notes, enabled, created_at",
        "vendor_name", vendor_name,
    )
    out["semantics"] = "keyed upsert on vendor_name: a re-ask updates the mapping in place"
    out["materialization"] = GOLD_MATERIALIZATION_NOTE
    return out


def _alias_key(alias_name: str) -> str:
    # The same normalization the MERGE computes in SQL.
    return re.sub(r"[^a-z0-9]+", "", (alias_name or "").lower())


def add_vendor_alias(
    alias_name: str, canonical_vendor_name: str, notes: str = "", *, actor: WriteActor
) -> dict:
    tool = "add_vendor_alias"
    args = {"alias_name": alias_name, "canonical_vendor_name": canonical_vendor_name}

    err = (field_error("alias_name", alias_name)
           or field_error("canonical_vendor_name", canonical_vendor_name)
           or field_error("notes", notes, required=False))
    if not err and not _alias_key(alias_name):
        err = "alias_name normalizes to an empty alias_key"
    if err:
        return _refuse(tool, actor, args, "invalid-field", error=err)

    key = _alias_key(alias_name)
    args["alias_key"] = key
    dml_params = [
        ("alias_name", "STRING", alias_name),
        ("canonical_vendor_name", "STRING", canonical_vendor_name),
        ("notes", "STRING", notes or ""),
    ]
    out = _run_write(tool, actor, args, _alias_dml(), dml_params, f"alias_key={key}")
    if out["status"] not in ("ok", "no-op"):
        return out
    out["row"] = _latest_row(
        tool, f"`{PROJECT}.{GOLD}.vendor_aliases`",
        "alias_key, alias_name, canonical_vendor_name, notes, enabled, created_at",
        "alias_key", key,
    )
    out["semantics"] = (
        "keyed upsert on the normalized alias_key: a re-ask updates the one "
        "row; the variant inherits whatever decision the canonical name has"
    )
    out["materialization"] = GOLD_MATERIALIZATION_NOTE
    return out


def _validate_priority(priority: Any) -> int | None:
    # Port of the bash twins' ^[0-9]+$ gate; accepts an int or digit string.
    if isinstance(priority, bool):
        return None
    if isinstance(priority, int) and priority >= 0:
        return priority
    if isinstance(priority, str) and re.match(r"^[0-9]+$", priority):
        return int(priority)
    return None


def _rule_args_error(
    rule_id: Any, priority: Any
) -> tuple[int | None, tuple[str, str, str | None] | None]:
    """Shared rule_id/priority gate for the two rule tools.

    Returns (validated priority, refusal), where refusal is None or the
    (code, error, row_key) triple to hand to _refuse."""
    if not isinstance(rule_id, str) or not RULE_ID_RE.match(rule_id or ""):
        return None, ("invalid-rule-id",
                      "rule_id must be a short slug (letters, digits, ._-)", None)
    prio = _validate_priority(priority)
    if prio is None:
        return None, ("invalid-priority",
                      "priority must be a non-negative integer",
                      f"rule_id={rule_id}")
    return prio, None


def add_classification_rule(
    rule_id: str,
    priority: Any,
    description_regex: str,
    category: str,
    subcategory: str = "",
    *,
    actor: WriteActor,
) -> dict:
    tool = "add_classification_rule"
    args = {"rule_id": rule_id, "priority": priority, "category": category,
            "subcategory": subcategory, "description_regex": description_regex}

    prio, refusal = _rule_args_error(rule_id, priority)
    if refusal:
        code, error, row_key = refusal
        return _refuse(tool, actor, args, code, error=error, row_key=row_key)
    err = (field_error("description_regex", description_regex)
           or field_error("category", category)
           or field_error("subcategory", subcategory, required=False))
    if err:
        return _refuse(tool, actor, args, "invalid-field", error=err,
                       row_key=f"rule_id={rule_id}")

    dml_params = [
        ("rule_id", "STRING", rule_id),
        ("priority", "INT64", prio),
        ("description_regex", "STRING", description_regex),
        ("category", "STRING", category),
        ("subcategory", "STRING", subcategory or ""),
    ]
    out = _run_write(tool, actor, args, _classification_rule_dml(), dml_params,
                     f"rule_id={rule_id}", pre_sql=_REGEX_GUARD)
    if out["status"] not in ("ok", "no-op"):
        return out
    row = _latest_row(
        tool, f"`{PROJECT}.{FINANCE}.classification_rules`",
        "rule_id, priority, description_regex, direction, category,\n"
        "       subcategory, enabled, created_at",
        "rule_id", rule_id,
    )
    proof = _read(
        "SELECT transaction_key, category, subcategory, classification_source\n"
        f"FROM `{PROJECT}.{FINANCE}.v_transactions_classified`\n"
        "WHERE classification_source = CONCAT('rule:', @rule_id) LIMIT 3",
        [("rule_id", "STRING", rule_id)],
        tool,
    )
    out["row"] = row
    out["classification_proof"] = proof or []
    if not proof:
        out["note"] = (
            "the rule landed but currently decides no transaction — either "
            "nothing matches the regex yet, or an override/lower-priority rule "
            "wins on every match"
        )
    out["semantics"] = (
        "keyed upsert on rule_id: a re-ask updates the one rule in place; "
        "rules are evaluated by ascending priority then rule_id; an override "
        "beats a rule"
    )
    out["materialization"] = GOLD_MATERIALIZATION_NOTE
    return out


def add_vendor_rule(
    rule_id: str,
    priority: Any,
    description_regex: str,
    vendor_name: str,
    notes: str = "",
    *,
    actor: WriteActor,
) -> dict:
    tool = "add_vendor_rule"
    args = {"rule_id": rule_id, "priority": priority, "vendor_name": vendor_name,
            "description_regex": description_regex}

    prio, refusal = _rule_args_error(rule_id, priority)
    if refusal:
        code, error, row_key = refusal
        return _refuse(tool, actor, args, code, error=error, row_key=row_key)
    err = (field_error("description_regex", description_regex)
           or field_error("vendor_name", vendor_name)
           or field_error("notes", notes, required=False))
    if err:
        return _refuse(tool, actor, args, "invalid-field", error=err,
                       row_key=f"rule_id={rule_id}")

    dml_params = [
        ("rule_id", "STRING", rule_id),
        ("priority", "INT64", prio),
        ("description_regex", "STRING", description_regex),
        ("vendor_name", "STRING", vendor_name),
        ("notes", "STRING", notes or ""),
    ]
    out = _run_write(tool, actor, args, _vendor_rule_dml(), dml_params,
                     f"rule_id={rule_id}", pre_sql=_REGEX_GUARD)
    if out["status"] not in ("ok", "no-op"):
        return out
    out["row"] = _latest_row(
        tool, f"`{PROJECT}.{GOLD}.vendor_rules`",
        "rule_id, priority, description_regex, vendor_name, notes,\n"
        "       enabled, created_at",
        "rule_id", rule_id,
    )
    out["semantics"] = (
        "keyed upsert on rule_id: a re-ask updates the one rule in place; "
        "vendor rules are evaluated by ascending priority after aliases; an "
        "override beats both"
    )
    out["materialization"] = GOLD_MATERIALIZATION_NOTE
    return out
