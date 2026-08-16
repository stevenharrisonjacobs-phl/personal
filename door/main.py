"""FastMCP entry point for the personal door.

Thin by design: tool declarations and docstrings only. Authorization lives in
service.py and the SQL perimeter lives in finance_native.py, so nothing here can
accidentally become the place a rule is enforced.

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


if __name__ == "__main__":
    mcp.run(
        transport="http",
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "8080")),
    )
