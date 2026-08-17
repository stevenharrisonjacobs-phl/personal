"""Run the repo's proven queries/*.sql by name, through the governed perimeter.

These are the questions that already have vetted SQL. Letting the model call one
by name beats having it re-derive `spend_amount` sign conventions and transfer
exclusions every session — and every saved query still passes through
`_validate_query`, so a file edited to do something unsafe is refused like any
other SQL.
"""

from __future__ import annotations

import os
from pathlib import Path

from . import finance_native

# The repo root as laid out in the container image (see Dockerfile).
QUERY_DIR = Path(
    os.environ.get("PERSONAL_DOOR_QUERY_DIR", Path(__file__).resolve().parent.parent / "queries")
)

# Placeholder substitution, mirroring scripts/lib.sh render_sql() so a saved
# query behaves identically through the door and through ./scripts/query.sh.
_SUBSTITUTIONS = {
    "__PROJECT_ID__": finance_native.PROJECT,
    "__FINANCE_DATASET__": finance_native.FINANCE,
    "__GOLD_DATASET__": finance_native.GOLD,
}

# tiller_raw is unreachable from the door by design, so any saved query that
# reads it is excluded from the catalog rather than failing at call time.
_RAW_DATASET_PLACEHOLDER = "__RAW_DATASET__"


def _render(text: str) -> str:
    for placeholder, value in _SUBSTITUTIONS.items():
        text = text.replace(placeholder, value)
    return text


def _catalog() -> dict[str, Path]:
    if not QUERY_DIR.is_dir():
        return {}
    found: dict[str, Path] = {}
    for path in sorted(QUERY_DIR.glob("*.sql")):
        text = path.read_text(encoding="utf-8", errors="replace")
        if _RAW_DATASET_PLACEHOLDER in text:
            continue
        found[path.stem] = path
    return found


def list_saved_queries() -> dict:
    """Names of the proven queries this door can run, with their first line."""
    catalog = _catalog()
    entries = []
    for name, path in catalog.items():
        text = path.read_text(encoding="utf-8", errors="replace")
        statement, error = finance_native._validate_query(_render(text))
        entries.append(
            {
                "name": name,
                "runnable": error is None,
                "blocked_because": error,
                "preview": " ".join(text.split())[:160],
            }
        )
    return {
        "status": "ok",
        "count": len(entries),
        "queries": entries,
        "note": (
            "Saved queries reading tiller_raw are excluded — those are external "
            "tables over the Google Sheet and the door holds no Drive credential."
        ),
    }


def saved_query(name: str, max_rows: int = 100) -> dict:
    """Run one proven query from queries/ by name."""
    key = (name or "").strip().removesuffix(".sql")
    catalog = _catalog()
    if key not in catalog:
        return {
            "status": "error",
            "error": f"unknown saved query: {key}",
            "valid_queries": sorted(catalog),
        }
    text = _render(catalog[key].read_text(encoding="utf-8", errors="replace"))
    result = finance_native.run_finance_query(text, max_rows=max_rows)
    if isinstance(result, dict):
        result["saved_query"] = key
    return result


FEED_HEALTH_SQL = f"""
SELECT
  account_name,
  account_number_masked,
  MAX(transaction_date) AS latest_transaction,
  DATE_DIFF(CURRENT_DATE(), MAX(transaction_date), DAY) AS days_since_latest,
  COUNTIF(transaction_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)) AS txns_last_30d
FROM `{finance_native.PROJECT}.{finance_native.GOLD}.transactions`
GROUP BY account_name, account_number_masked
ORDER BY days_since_latest DESC, account_name
"""


def feed_health(max_rows: int = 100) -> dict:
    """Per-account feed freshness — the check that catches a silently dead feed.

    Judge accounts against EACH OTHER, never an absolute threshold: an account
    with many txns_last_30d but a days_since_latest far above the other active
    cards has a broken feed. Low-activity accounts (trusts, retirement) are
    naturally stale and are not a problem.
    """
    result = finance_native.run_finance_query(FEED_HEALTH_SQL, max_rows=max_rows)
    if isinstance(result, dict) and result.get("status") == "ok":
        result["how_to_read"] = (
            "Compare accounts to each other. A high txns_last_30d with a high "
            "days_since_latest means a broken feed — the fix is to reconnect "
            "that account in Tiller, which is a source-side action, not a repo "
            "change. Naturally-stale accounts (trusts, retirement) are fine."
        )
    return result
