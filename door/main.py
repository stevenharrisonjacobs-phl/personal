"""FastMCP entry point for the personal door.

Thin by design: tool declarations and docstrings only. Authorization lives in
service.py, the read perimeter in finance_native.py, and the governed write
path in finance_write.py, so nothing here can accidentally become the place a
rule is enforced.

The docstrings ARE the interface — they are what the connected Claude session
reads to decide which tool to call, so they carry the usage rules (sign
conventions, exclusions, coverage caveats) rather than restating the code.
"""

from __future__ import annotations

import os
from typing import Any

from fastmcp import FastMCP

from door.auth import build_auth, current_identity
from door.service import DoorService

auth = build_auth()
service = DoorService.from_env()
mcp = FastMCP("personal-door", auth=auth)


@mcp.tool
def door_whoami() -> dict[str, Any]:
    """Which Google identity is this session, and is it enrolled on this door?

    Call once at the start of a session. If `authorized` is false, say so and
    stop — the fix is reconnecting with the enrolled account, never a retry.
    """
    return service.whoami(current_identity())


@mcp.tool
def list_finance_sources() -> dict[str, Any]:
    """List the governed finance sources — each view's grain and purpose.

    Start here for any structured question. Read-only; no model or embedding
    API is called. Prefer the gold.* models over recomposing from finance.*.
    """
    return service.list_finance_sources(current_identity())


@mcp.tool
def describe_finance_source(source: str) -> dict[str, Any]:
    """Describe one governed source's LIVE BigQuery schema and grain.

    Use an exact name from `list_finance_sources`. Always call this before
    writing novel SQL — never guess column names.
    """
    return service.describe_finance_source(current_identity(), source)


@mcp.tool
def run_finance_query(
    sql: str, max_rows: int = 100, dry_run: bool = False
) -> dict[str, Any]:
    """Run one capped, read-only SQL query over the governed finance catalog.

    Only SELECT/WITH over whitelisted finance.* and gold.* sources is accepted.
    DML, DDL, multiple statements, remote queries, and ML/AI functions are
    rejected, as is tiller_raw (external tables over the Google Sheet). Every
    execution is dry-run validated first, capped at 1 GiB billed and 500 rows.

    Reporting rules that make an answer correct rather than merely returned:
      - Tiller expenses are NEGATIVE. Use finance.v_spending.spend_amount for
        positive spend.
      - Transfers and credit-card payments are not spending — filter flow_type.
      - Any INCOME answer must also include finance.v_manual_income, prorated to
        the range; it is additive, not a double-count.
      - Always state the date range and whether transfers, refunds, income, and
        uncategorized transactions were included.
    """
    return service.run_finance_query(
        current_identity(), sql, max_rows=max_rows, dry_run=dry_run
    )


@mcp.tool
def list_saved_queries() -> dict[str, Any]:
    """List the repo's proven, vetted queries that can be run by name.

    Check here before writing novel SQL — a saved query already encodes the
    sign conventions and exclusions for its question.
    """
    return service.list_saved_queries(current_identity())


@mcp.tool
def saved_query(name: str, max_rows: int = 100) -> dict[str, Any]:
    """Run one proven query by name (see `list_saved_queries`).

    Examples: monthly-spending, top-vendors, current-balances, account-summary,
    categories, epics, flow-summary, flow-review, manual-income, uncategorized.
    """
    return service.saved_query(current_identity(), name, max_rows=max_rows)


@mcp.tool
def feed_health(max_rows: int = 100) -> dict[str, Any]:
    """Per-account feed freshness — is any bank feed silently broken?

    Run this before trusting ANY finance answer: a dead feed makes a confident
    answer quietly wrong. Compare accounts to each other, not to an absolute
    threshold. A high transaction count with a stale latest date means a broken
    feed; the fix is reconnecting that account in Tiller (source-side, not a
    repo change). Low-activity accounts are naturally stale and are fine.
    """
    return service.feed_health(current_identity(), max_rows=max_rows)


@mcp.tool
def record_checkin(payload: dict[str, Any]) -> dict[str, Any]:
    """Land a SUCCESSFUL daily spend check-in row in finance.checkin_reports.

    The payload contract (all timestamps RFC3339 UTC strings):
      {run_ts, consumed_checkpoint, window_start, window_end,
       sources: {mirror|vantage|live_costs|mercury:
                   {window_start, window_end, status, total, note}},
       totals: {personal_cash, mercury_cash, cloud_billed, cloud_live},
       report_md}

    Integrity rules enforced server-side (a refusal names its reason):
      - window_start must equal the consumed checkpoint (contiguity), the
        headline totals must equal the per-source totals, at least one source
        must be ok, and no field may carry an account-number-like digit run.
      - The checkpoint is re-resolved immediately before the write; if another
        run landed in between, this refuses — recompose against the live
        checkpoint rather than retrying blindly.
      - A duplicate fire for the same window is a no-op, not a second row.
    Returns the confirmed durable row. If generation FAILED, do not call this —
    call record_checkin_failed instead.
    """
    return service.record_checkin(current_identity(), payload)


@mcp.tool
def record_checkin_failed(reason: str = "") -> dict[str, Any]:
    """Record that a daily spend check-in run FAILED, without artifacts.

    Lands a zero-length-window status='failed' row that can never advance the
    checkpoint or block a later success. `reason` must be ONE line, at most
    300 characters, with no long digit runs; a violating reason is replaced by
    an enumerated generic code and the row still lands — recording a failure
    never itself fails. Call this whenever check-in generation cannot produce
    a valid success payload.
    """
    return service.record_checkin_failed(current_identity(), reason)


@mcp.tool
def reclassify_transaction(
    transaction_key: str, category: str, notes: str = ""
) -> dict[str, Any]:
    """Correct one transaction's category (the strongest classification source).

    Appends to finance.transaction_overrides: an override beats every rule and
    the Tiller category, and the latest override for a key wins — history is
    kept, nothing is deleted. The key must be the 64-hex transaction_key from
    gold.transactions and must exist in the mirror (verified before writing).
    Returns the durable override row PLUS the finance.v_transactions_classified
    row proving classification_source='override'. gold.transactions
    materializes within the hour — do not re-query it to verify.
    """
    return service.reclassify_transaction(
        current_identity(), transaction_key, category, notes
    )


@mcp.tool
def set_vendor_override(
    transaction_key: str, vendor_name: str, notes: str = ""
) -> dict[str, Any]:
    """Correct one transaction's vendor identity (highest-priority source).

    Appends to gold.transaction_vendor_overrides; latest row per key wins.
    Use for a single mis-resolved transaction. If the SAME merchant keeps
    arriving under a variant descriptor, prefer add_vendor_alias (fixes every
    occurrence); for a recurring pattern, add_vendor_rule. Returns the durable
    row; gold.transactions materializes within the hour.
    """
    return service.set_vendor_override(
        current_identity(), transaction_key, vendor_name, notes
    )


@mcp.tool
def set_flow_override(
    transaction_key: str, flow_type: str, notes: str = ""
) -> dict[str, Any]:
    """Correct one transaction's flow_type, clearing it from flow review.

    Appends to gold.transaction_flow_overrides; latest row per key wins. Known
    flow types: earned_income, investment_income, internal_transfer,
    capital_proceeds, refund_reimbursement, expense (lowercase token required).
    This is how rows leave gold.transaction_flow_review — never silently
    coerce an unresolved flow in analysis; land the override instead. Returns
    the durable row; gold.transactions materializes within the hour.
    """
    return service.set_flow_override(
        current_identity(), transaction_key, flow_type, notes
    )


@mcp.tool
def add_vendor_mapping(
    vendor_name: str, category_id: str, notes: str = ""
) -> dict[str, Any]:
    """Map a merchant to a canonical category — the "known classifications" table.

    Upserts gold.vendor_category_map keyed on vendor_name (a re-ask updates the
    mapping in place). This is the FIRST source consulted for a category, ahead
    of the regex rules; only a per-transaction override beats it. category_id
    is validated against the LIVE gold.categories typology — a refusal returns
    the valid ids. Returns the durable row; gold.transactions materializes
    within the hour.
    """
    return service.add_vendor_mapping(current_identity(), vendor_name, category_id, notes)


@mcp.tool
def add_vendor_alias(
    alias_name: str, canonical_vendor_name: str, notes: str = ""
) -> dict[str, Any]:
    """Collapse a descriptor variant onto a canonical merchant.

    Upserts gold.vendor_aliases keyed on the normalized alias_key. The right
    tool when the SAME merchant arrives under several descriptors ("Shake
    Shack Pa" -> "Shake Shack"): the variant inherits whatever category
    decision the canonical name already has — do NOT also add a
    vendor_category_map row for the variant. Returns the durable row;
    gold.transactions materializes within the hour.
    """
    return service.add_vendor_alias(
        current_identity(), alias_name, canonical_vendor_name, notes
    )


@mcp.tool
def add_classification_rule(
    rule_id: str,
    priority: int,
    description_regex: str,
    category: str,
    subcategory: str = "",
) -> dict[str, Any]:
    """Add a regex rule assigning a category to matching EXPENSE transactions.

    Appends to finance.classification_rules (direction fixed to 'expense',
    like the repo's guarded writer). Rules are evaluated by ascending priority
    then rule_id; an override beats any rule. Rules exist for merchants never
    seen before — for a KNOWN merchant prefer add_vendor_mapping. The regex is
    RE2 (BigQuery REGEXP_CONTAINS) and is validated before anything lands.
    Returns the durable row plus up to three v_transactions_classified rows
    proving classification_source='rule:<rule_id>' (empty if nothing matches
    yet).
    """
    return service.add_classification_rule(
        current_identity(), rule_id, priority, description_regex, category, subcategory
    )


@mcp.tool
def add_vendor_rule(
    rule_id: str,
    priority: int,
    description_regex: str,
    vendor_name: str,
    notes: str = "",
) -> dict[str, Any]:
    """Add a regex rule mapping matching descriptions to a vendor.

    Appends to gold.vendor_rules, evaluated by ascending priority AFTER exact
    aliases; a per-transaction vendor override beats both. The regex is RE2
    and validated before anything lands. Returns the durable row;
    gold.transactions materializes within the hour.
    """
    return service.add_vendor_rule(
        current_identity(), rule_id, priority, description_regex, vendor_name, notes
    )


if __name__ == "__main__":
    mcp.run(
        transport="http",
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "8080")),
    )
