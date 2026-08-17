"""Governed, model-free finance analytics primitives for the personal door.

Every function is read-only and uses BigQuery only. No LLM or embedding API is
called at query time; the connected Claude session does the planning and
synthesis. The SQL validator is ported from `snapfix/door/gtm_native.py` —
generic safety regex, with the source whitelist replaced wholesale.

Deliberately absent from the whitelist:
  tiller_raw.*   external tables over the Tiller Google Sheet. Reading them
                 needs Drive credentials the door does not and must not hold.
  the write surface (classification_rules, transaction_overrides, vendor_rules,
                 vendor_aliases, transaction_*_overrides) — the door is
                 read-only, so surfacing them would only invite a write attempt.
"""

from __future__ import annotations

import datetime as dt
import decimal
import os
import re
from typing import Any

from google.cloud import bigquery

PROJECT = os.environ.get("GCP_PROJECT_ID", "steven-tiller-finance-2026")
FINANCE = os.environ.get("FINANCE_DATASET", "finance")
GOLD = os.environ.get("GOLD_DATASET", "gold")

# These datasets are small; 1 GiB is a generous ceiling that still stops a
# runaway cross join from becoming a surprise bill.
MAX_BYTES_BILLED = 1024**3
MAX_QUERY_ROWS = 500

_client: bigquery.Client | None = None


def _bq() -> bigquery.Client:
    global _client
    if _client is None:
        _client = bigquery.Client(project=PROJECT)
    return _client


# The agent-facing semantic perimeter, keyed "dataset.table".
#
# GOLD-FIRST: the gold models encode the business definitions — deduplication,
# canonical flow type, vendor identity, the category typology — so prefer them
# over recomposing from finance.*. The finance.* views remain for balances, net
# worth, manual (off-mirror) lines, and the projection assumptions.
SOURCES: dict[str, dict[str, str]] = {
    # ---- gold: the analysis models (prefer these) ----
    f"{GOLD}.transactions": {
        "grain": "transaction",
        "summary": "THE default transaction model. One row per transaction key, deduplicated, with vendor id/name, category, canonical flow_type, confidence/evidence, cash-flow direction, positive spend/income/refund measures, transfer/refund flags, and calendar fields.",
    },
    f"{GOLD}.transactions_base": {
        "grain": "transaction (pre-enrichment)",
        "summary": "The deduplicated base behind gold.transactions, before vendor/flow enrichment. Use only when you need to see what enrichment changed.",
    },
    f"{GOLD}.vendors": {
        "grain": "inferred vendor",
        "summary": "One row per resolved vendor with primary category, observed categories, activity dates, transaction counts, and spend metrics.",
    },
    f"{GOLD}.accounts": {
        "grain": "account",
        "summary": "One row per account across both transaction and balance sources, with latest balance and lifetime activity.",
    },
    f"{GOLD}.categories": {
        "grain": "category",
        "summary": "The durable two-level category typology derived from the Copilot export. This is the canonical taxonomy.",
    },
    f"{GOLD}.category_aliases": {
        "grain": "source category label",
        "summary": "Maps Copilot and Tiller category labels into the canonical typology. Join here before trusting a raw source_category.",
    },
    f"{GOLD}.epics": {
        "grain": "epic",
        "summary": "Trips, renovations, celebrations and other bounded projects, kept separate from the category typology. A large purchase is NOT an epic.",
    },
    f"{GOLD}.epic_transactions": {
        "grain": "epic-transaction assignment",
        "summary": "Each Copilot epic assignment, linked to a Tiller transaction only on a unique date + absolute-amount + account-suffix match. Unlinked rows still count toward epic totals.",
    },
    f"{GOLD}.transaction_flow_review": {
        "grain": "transaction needing flow review",
        "summary": "Transactions whose flow_type cannot be safely resolved from source evidence. Never silently coerce these into income or transfers — report them as unresolved.",
    },
    f"{GOLD}.transaction_anomaly_review_queue": {
        "grain": "reviewed anomaly",
        "summary": "Session-reviewed anomalies and source ambiguities. Review material only; suggestions are never auto-applied.",
    },
    f"{GOLD}.vendor_canonical_review": {
        "grain": "observed vendor label",
        "summary": "Every observed vendor label with its canonical name, mapping method, confidence, and review status.",
    },
    f"{GOLD}.copilot_transaction_matches": {
        "grain": "transaction with a verified Copilot match",
        "summary": "One-to-one links between a Tiller transaction and its Copilot row, carrying the hand-reviewed Copilot category. This is the evidence behind category refinement — read it to explain WHY a transaction is categorized as it is.",
    },
    f"{GOLD}.v_projection": {
        "grain": "projected period",
        "summary": "Forward projection built on finance.assumptions. Advisor-review surface; state the assumption set behind any number taken from here.",
    },
    f"{GOLD}.v_accrued_costs": {
        "grain": "accrued cost line",
        "summary": "Costs recognized in the period they belong to rather than when cash moved. Pairs with finance.accruals.",
    },
    f"{GOLD}.v_spending_accrued": {
        "grain": "period x category",
        "summary": "Spending on an accrual basis — the 'what did this period really cost' view.",
    },
    f"{GOLD}.v_spending_amortized": {
        "grain": "period x category",
        "summary": "Spending with lumpy commitments spread over their term (see gold.amortization_schedule). This is the monthly-nut view; do NOT mix it with real-cash spending in one total.",
    },
    f"{GOLD}.v_business_revenue_monthly": {
        "grain": "month",
        "summary": "Business revenue by month, separated from household income.",
    },
    f"{GOLD}.amortization_schedule": {
        "grain": "committed cost x period",
        "summary": "How each lumpy commitment is spread across periods. The definition behind v_spending_amortized.",
    },
    # ---- finance: balances, net worth, off-mirror lines, assumptions ----
    f"{FINANCE}.v_transactions_classified": {
        "grain": "transaction",
        "summary": "All normalized transactions plus their final classification and which source decided it (override > rule > Tiller category).",
    },
    f"{FINANCE}.v_spending": {
        "grain": "outflow",
        "summary": "Outflows with a POSITIVE spend_amount. Tiller stores expenses as negative — use this view whenever reporting spend, or the sign will be wrong.",
    },
    f"{FINANCE}.v_current_balances": {
        "grain": "account",
        "summary": "Latest balance per account. Union this with finance.manual_balances for a complete picture — some accounts have no bank feed.",
    },
    f"{FINANCE}.v_monthly_net_worth": {
        "grain": "month",
        "summary": "Month-end net worth history.",
    },
    f"{FINANCE}.v_manual_income": {
        "grain": "manual income line",
        "summary": "Off-mirror income tracked by hand from statements/PDFs (no bank feed). ANY income answer must add these, prorated by the range. They are additive, not double-counted — see the context library before using.",
    },
    f"{FINANCE}.manual_income": {
        "grain": "manual income line",
        "summary": "The base table behind v_manual_income.",
    },
    f"{FINANCE}.manual_balances": {
        "grain": "off-mirror account balance",
        "summary": "Balances for accounts with no bank feed, maintained by hand. Unioned into balance history by the refresh job.",
    },
    f"{FINANCE}.balance_history": {
        "grain": "account x date",
        "summary": "Append-only balance history — the durable source behind every balance and net-worth view.",
    },
    f"{FINANCE}.accruals": {
        "grain": "accrual line",
        "summary": "Manual accrual definitions feeding gold.v_accrued_costs.",
    },
    f"{FINANCE}.assumptions": {
        "grain": "assumption",
        "summary": "Projection assumptions (rates, growth, planned changes). State which assumptions a projection used.",
    },
    f"{FINANCE}.v_assumptions_current": {
        "grain": "assumption",
        "summary": "The currently-effective assumption set.",
    },
    # ---- classification lookups (READ-only; they explain why a label exists) ----
    # These are the tables the add-*.sh scripts write. Reading them is what lets
    # an answer explain "why is this vendor called that" instead of guessing,
    # and several vetted queries in queries/ depend on them. They hold mappings
    # and notes, not amounts. The door has no write tools at all, so there is no
    # write path here to invite — unlike tiller_raw, whose exclusion is a real
    # technical boundary (Drive credentials), not a precaution.
    f"{GOLD}.vendor_aliases": {
        "grain": "vendor alias",
        "summary": "Exact description->vendor alias lookup. First step of vendor identity resolution.",
    },
    f"{GOLD}.vendor_rules": {
        "grain": "vendor regex rule",
        "summary": "Regex rules mapping descriptions to vendors, evaluated by priority after aliases.",
    },
    f"{GOLD}.vendor_category_map": {
        "grain": "vendor",
        "summary": "Vendor to primary-category mapping.",
    },
    f"{GOLD}.transaction_vendor_overrides": {
        "grain": "transaction",
        "summary": "Per-transaction vendor corrections. Highest-priority step in vendor resolution.",
    },
    f"{GOLD}.transaction_flow_overrides": {
        "grain": "transaction",
        "summary": "Per-transaction flow_type corrections, used to clear rows out of transaction_flow_review.",
    },
    f"{GOLD}.epic_definitions": {
        "grain": "epic label",
        "summary": "The lookup deciding which Copilot project labels are promoted to epics. Transfers, taxes, and annual subscriptions are deliberately not epics.",
    },
    f"{FINANCE}.classification_rules": {
        "grain": "classification rule",
        "summary": "Regex rules assigning category/subcategory, evaluated in ascending priority. A rule beats the Tiller category; an override beats a rule.",
    },
    f"{FINANCE}.transaction_overrides": {
        "grain": "transaction",
        "summary": "Per-transaction category corrections — the highest-priority classification source.",
    },
}

_LINE_COMMENT = re.compile(r"--[^\n]*")
_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)
_FORBIDDEN = re.compile(
    r"\b(?:INSERT|UPDATE|DELETE|MERGE|CREATE|DROP|ALTER|TRUNCATE|CALL|EXPORT|LOAD|GRANT|REVOKE)\b",
    re.IGNORECASE,
)
_REMOTE_MODEL = re.compile(r"\b(?:EXTERNAL_QUERY|ML\.|AI\.)", re.IGNORECASE)
_FROM_JOIN = re.compile(r"\b(?:FROM|JOIN)\s+(`[^`]+`|[A-Za-z0-9_.-]+)", re.IGNORECASE)
_STRING_LITERAL = re.compile(r"'(?:''|\\.|[^'])*'", re.DOTALL)

# Columns whose values are full account or card numbers. Redacted before
# results leave the door — an answer never needs the full number, and a chat
# transcript is a worse place to keep one than a bank statement.
#
# Matched by PATTERN, not a fixed list, so a column added upstream is caught
# without a door release. The `*_masked` forms are deliberately EXEMPT: they are
# already truncated, and they are how two accounts with the same name are told
# apart (`gold.transactions.account_number_masked`).
_REDACT_COLUMN = re.compile(
    r"(?:account|card|routing|iban)_?(?:number|no|num)$", re.IGNORECASE
)


def _should_redact(column: str) -> bool:
    name = (column or "").strip().lower()
    if name.endswith("_masked") or name.endswith("_mask"):
        return False
    return bool(_REDACT_COLUMN.search(name))


def list_finance_sources() -> dict:
    """The governed source catalog: every readable view, its grain and purpose."""
    return {
        "status": "ok",
        "project": PROJECT,
        "datasets": sorted({FINANCE, GOLD}),
        "read_only": True,
        "model_api_calls": False,
        "sources": [{"source": name, **meta} for name, meta in SOURCES.items()],
    }


def describe_finance_source(source: str) -> dict:
    """Live BigQuery schema for one governed source. Never guess columns."""
    name = (source or "").strip()
    if name not in SOURCES:
        return {
            "status": "error",
            "error": f"unknown finance source: {name}",
            "valid_sources": sorted(SOURCES),
        }
    try:
        table = _bq().get_table(f"{PROJECT}.{name}")
    except Exception as exc:
        return {
            "status": "error",
            "error": f"could not describe {name}: {str(exc)[:300]}",
        }
    return {
        "status": "ok",
        "source": name,
        **SOURCES[name],
        "columns": [
            {
                "name": field.name,
                "type": field.field_type,
                "mode": field.mode,
                "description": field.description or None,
            }
            for field in table.schema
        ],
        "rules": [
            "Tiller expenses are negative; use finance.v_spending.spend_amount for positive spend.",
            "Transfers and credit-card payments are not spending — filter on flow_type.",
            "Prefer the gold models over recomposing from finance.*.",
            "Any income answer must also include finance.v_manual_income, prorated.",
        ],
    }


def _strip_comments(sql: str) -> str:
    return _BLOCK_COMMENT.sub(" ", _LINE_COMMENT.sub(" ", sql))


def _validate_query(sql: str) -> tuple[str | None, str | None]:
    """Return (statement, None) if the SQL is safe to run, else (None, reason).

    Pure function — no GCP needed, so the test suite covers it offline.
    """
    statement = (sql or "").strip()
    if not statement:
        return None, "sql is required"
    cleaned = _strip_comments(statement).strip()
    masked = _STRING_LITERAL.sub("''", cleaned)
    if masked.endswith(";"):
        cleaned = cleaned[:-1].rstrip()
        masked = masked[:-1].rstrip()
        statement = statement.rstrip()[:-1].rstrip()
    if ";" in masked:
        return None, "only one SQL statement is allowed"
    if not re.match(r"^(?:SELECT|WITH)\b", masked, re.IGNORECASE):
        return None, "only a SELECT or WITH query is allowed"
    if _FORBIDDEN.search(masked):
        return None, "data modification and DDL are not allowed"
    if _REMOTE_MODEL.search(masked):
        return None, "remote queries and model/AI functions are not allowed"

    for match in _FROM_JOIN.finditer(masked):
        token = match.group(1).strip("`")
        # CTE references have no dataset qualifier and are allowed.
        if "." not in token:
            continue
        parts = token.split(".")
        if len(parts) not in (2, 3):
            return None, f"unsupported table reference: {token}"
        dataset, table = parts[-2], parts[-1]
        project = parts[-3] if len(parts) == 3 else PROJECT
        qualified = f"{dataset}.{table}"
        if project != PROJECT:
            return None, f"source is outside this project: {token}"
        if dataset not in (FINANCE, GOLD):
            hint = (
                " tiller_raw holds external tables over the Google Sheet and is"
                " deliberately unreachable from the door; use the finance.* or"
                " gold.* models instead."
                if dataset.startswith("tiller")
                else ""
            )
            return None, f"dataset is outside the governed catalog: {token}.{hint}"
        if qualified not in SOURCES:
            return None, f"source is outside the governed catalog: {token}"
    return statement, None


def _json_value(value: Any) -> Any:
    if isinstance(value, (dt.date, dt.datetime, dt.time)):
        return value.isoformat()
    if isinstance(value, decimal.Decimal):
        return float(value)
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    if isinstance(value, (tuple, list)):
        return [_json_value(item) for item in value]
    if isinstance(value, dict):
        return {key: _json_value(item) for key, item in value.items()}
    return value


def _redact_row(row: dict) -> dict:
    return {
        key: ("[redacted]" if _should_redact(key) and value else value)
        for key, value in row.items()
    }


def run_finance_query(sql: str, max_rows: int = 100, dry_run: bool = False) -> dict:
    """Run one capped, read-only SELECT/WITH over the governed catalog."""
    statement, error = _validate_query(sql)
    if error:
        return {"status": "error", "error": error}
    try:
        safe_rows = max(1, min(int(max_rows), MAX_QUERY_ROWS))
    except (TypeError, ValueError):
        safe_rows = 100

    client = _bq()
    try:
        estimate_job = client.query(
            statement,
            job_config=bigquery.QueryJobConfig(
                dry_run=True,
                use_query_cache=False,
                maximum_bytes_billed=MAX_BYTES_BILLED,
                labels={"tool": "run_finance_query"},
            ),
        )
        estimated = int(estimate_job.total_bytes_processed or 0)
    except Exception as exc:
        return {"status": "error", "error": f"query validation failed: {str(exc)[:500]}"}
    if dry_run:
        return {
            "status": "ok",
            "dry_run": True,
            "estimated_bytes_processed": estimated,
            "estimated_gib": round(estimated / 1024**3, 4),
        }

    try:
        job = client.query(
            statement,
            job_config=bigquery.QueryJobConfig(
                maximum_bytes_billed=MAX_BYTES_BILLED,
                labels={"tool": "run_finance_query"},
            ),
        )
        iterator = job.result()
        rows: list[dict] = []
        truncated = False
        for index, row in enumerate(iterator):
            if index >= safe_rows:
                truncated = True
                break
            rows.append(
                _redact_row({key: _json_value(value) for key, value in dict(row).items()})
            )
    except Exception as exc:
        return {"status": "error", "error": f"query failed: {str(exc)[:500]}"}

    return {
        "status": "ok",
        "columns": [field.name for field in (iterator.schema or [])],
        "result_count": len(rows),
        "truncated": truncated,
        "max_rows": safe_rows,
        "bytes_processed": int(job.total_bytes_processed or 0),
        "results": rows,
    }
