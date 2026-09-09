#!/usr/bin/env python3
"""mercury_pull.py — deterministic Mercury REST fetch for the daily spend
check-in. Pulls the account list plus every account's transactions for BOTH
the requested window and the week-prior baseline window (start-7d..end-7d),
and writes the raw JSON into --out.

Axis note: Mercury's start/end query params filter on createdAt, but the
check-in counts on postedAt (card charges post 1+ days after creation). So
each fetch WIDENS the createdAt params — (window_start - 30d) through
(window_end + 1d), same widening for the baseline — and then filters
client-side on each transaction's postedAt to the exact half-open window
[start, end), matching the collector's window math in spend_checkin_costs.py.
A transaction with null/absent postedAt hasn't posted and is excluded. That
posted-window membership test is the ONLY client-side filtering — still NO
counting or classification decisions; the agent applies counting rules
separately.

Auth: MERCURY_API_TOKEN as a Bearer token, unless MERCURY_AUTH=proxy (the
platform proxy injects credentials; no local Authorization header is built
and the missing-token guard is suppressed).

Failure discipline: any HTTP or network error (or an account whose pagination
exhausts the defensive cap) → nonzero exit with ONE stderr line naming the
failure, and NO output files — everything is fetched into memory first and
written only after all pulls succeed. Writes themselves go to temp files that
are renamed into place only after every write succeeded, so a partial run
never leaves misleading or mixed (fresh-beside-stale) files behind.

Outputs in --out (default .context/checkin):
  accounts.json               raw GET /accounts response
  transactions-window.json    {"window": {...}, "accounts": {id: [txn, ...]}}
  transactions-prev.json      same shape for the week-prior baseline

Usage: mercury_pull.py --start 2026-09-07T10:00:00Z --end 2026-09-08T10:00:00Z [--out DIR]
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
from datetime import datetime, timedelta, timezone
from urllib.parse import urlencode, urlparse

from collector_common import _http_get_json, parse_iso

MERCURY_API = "https://api.mercury.com/api/v1"
DEFAULT_OUT = ".context/checkin"
USAGE = "usage: mercury_pull.py --start <utc-ts> --end <utc-ts> [--out DIR]"
PAGE_LIMIT = 500
MAX_PAGES = 50  # defensive cap; a window should never come close
# createdAt widening for the API params (which are createdAt-axis, not
# postedAt): look back far enough that anything POSTED in the window is
# fetched even if it was created long before, plus a day of forward slack.
FETCH_LOOKBACK_DAYS = 30


# ---- pure helpers -----------------------------------------------------------

def iso_z(t: datetime) -> str:
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def window_params(start_iso: str, end_iso: str) -> dict:
    """Exact posted-axis timestamps for the requested window ("window_ts")
    and the week-prior baseline ("prev_ts"), plus the WIDENED YYYY-MM-DD
    createdAt ranges ("fetch"/"prev_fetch") sent as the API's start/end
    params."""
    start, end = parse_iso(start_iso), parse_iso(end_iso)
    prev_start, prev_end = start - timedelta(days=7), end - timedelta(days=7)

    def fetch_range(w_start: datetime, w_end: datetime) -> tuple[str, str]:
        return ((w_start - timedelta(days=FETCH_LOOKBACK_DAYS)).date().isoformat(),
                (w_end + timedelta(days=1)).date().isoformat())

    return {
        "window_ts": (start, end),
        "prev_ts": (prev_start, prev_end),
        "fetch": fetch_range(start, end),
        "prev_fetch": fetch_range(prev_start, prev_end),
    }


def transactions_url(account_id: str, created_start: str, created_end: str,
                     limit: int, offset: int) -> str:
    query = urlencode({"limit": limit, "offset": offset,
                       "start": created_start, "end": created_end})
    return f"{MERCURY_API}/account/{account_id}/transactions?{query}"


def posted_in_window(txn: dict, w_start: datetime, w_end: datetime) -> bool:
    """True iff the transaction POSTED inside the half-open [w_start, w_end)
    — the same convention as spend_checkin_costs.py's bucketing. A null or
    absent postedAt means the transaction hasn't posted yet: excluded."""
    posted = txn.get("postedAt")
    if not posted:
        return False
    t = parse_iso(posted)
    if t.tzinfo is None:
        t = t.replace(tzinfo=timezone.utc)
    return w_start <= t < w_end


def parse_args(argv):
    start = end = ""
    out = DEFAULT_OUT
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg == "--start" and args:
            start = args.pop(0)
        elif arg == "--end" and args:
            end = args.pop(0)
        elif arg == "--out" and args:
            out = args.pop(0)
        elif arg in ("--start", "--end", "--out"):
            raise ValueError(USAGE)
        else:
            raise ValueError(f"unknown arg: {arg}\n{USAGE}")
    if not (start and end):
        raise ValueError(USAGE)
    return start, end, out


# ---- fetch ------------------------------------------------------------------

def fetch_transactions(http_get, headers, account_id, created_start, created_end):
    """One account, one widened createdAt range, paginated defensively
    (limit/offset; the API's paging fields are handled if present, single page
    assumed if absent). Exhausting MAX_PAGES without completing is an ERROR —
    returning silently would hand back partial data."""
    collected = []
    offset = 0
    total = None
    for _ in range(MAX_PAGES):
        data = http_get(transactions_url(account_id, created_start, created_end,
                                         PAGE_LIMIT, offset), headers)
        page = data.get("transactions") or []
        collected.extend(page)
        total = data.get("total")
        if not page or total is None or len(collected) >= total:
            return collected
        offset += len(page)
    raise RuntimeError(
        f"pagination exhausted for account {account_id}: fetched"
        f" {len(collected)} of {total} transactions in {MAX_PAGES} pages")


def run(argv, env, http_get):
    try:
        start, end, out_dir = parse_args(argv)
        params = window_params(start, end)
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 64

    proxied = env.get("MERCURY_AUTH") == "proxy"
    token = env.get("MERCURY_API_TOKEN")
    if not token and not proxied:
        print("mercury pull failed: MERCURY_API_TOKEN missing from env"
              " (or set MERCURY_AUTH=proxy)", file=sys.stderr)
        return 78
    headers = {} if proxied else {"Authorization": f"Bearer {token}"}

    start_ts, end_ts = params["window_ts"]
    prev_start, prev_end = params["prev_ts"]
    # Fetch EVERYTHING before writing anything: a failure mid-pull must not
    # leave partial output files behind. Each fetch uses the widened createdAt
    # params and is then filtered client-side on postedAt to the exact window.
    try:
        accounts_raw = http_get(f"{MERCURY_API}/accounts", headers)
        window_txns, prev_txns = {}, {}
        for account in accounts_raw.get("accounts") or []:
            account_id = account.get("id")
            if not account_id:
                continue
            window_txns[account_id] = [
                t for t in fetch_transactions(
                    http_get, headers, account_id, *params["fetch"])
                if posted_in_window(t, start_ts, end_ts)]
            prev_txns[account_id] = [
                t for t in fetch_transactions(
                    http_get, headers, account_id, *params["prev_fetch"])
                if posted_in_window(t, prev_start, prev_end)]
    except RuntimeError as exc:
        print(f"mercury pull failed: {exc}", file=sys.stderr)
        return 1
    except urllib.error.HTTPError as exc:
        where = urlparse(getattr(exc, "url", "") or "").path or "mercury api"
        if exc.code == 401:
            print(f"mercury pull failed: HTTP 401 unauthorized on {where}"
                  " — check MERCURY_API_TOKEN / MERCURY_AUTH", file=sys.stderr)
        else:
            print(f"mercury pull failed: HTTP {exc.code} on {where}",
                  file=sys.stderr)
        return 1
    except urllib.error.URLError as exc:
        reason = str(getattr(exc, "reason", exc)).replace("\n", " ")
        print(f"mercury pull failed: network error: {reason}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"mercury pull failed: network error: {type(exc).__name__}: {exc}",
              file=sys.stderr)
        return 1

    os.makedirs(out_dir, exist_ok=True)
    outputs = {
        "accounts.json": accounts_raw,
        "transactions-window.json": {
            "window": {"start": start, "end": end,
                       "created_fetch_start": params["fetch"][0],
                       "created_fetch_end": params["fetch"][1]},
            "accounts": window_txns,
        },
        "transactions-prev.json": {
            "window": {"start": iso_z(prev_start), "end": iso_z(prev_end),
                       "created_fetch_start": params["prev_fetch"][0],
                       "created_fetch_end": params["prev_fetch"][1]},
            "accounts": prev_txns,
        },
    }
    # Write-then-rename: every payload lands in a temp file first, and the
    # final names only appear (via os.replace) after ALL temp writes succeed
    # — a failure mid-write must not leave a mixed set of fresh files beside
    # stale ones. On failure the temps are removed and prior outputs stand.
    tmp_paths = {name: os.path.join(out_dir, f".{name}.tmp") for name in outputs}
    try:
        for name, payload in outputs.items():
            with open(tmp_paths[name], "w") as f:
                json.dump(payload, f, indent=1)
    except Exception as exc:  # noqa: BLE001 — clean temps, keep prior outputs
        for tmp in tmp_paths.values():
            try:
                os.remove(tmp)
            except FileNotFoundError:
                pass
        detail = str(exc).replace("\n", " ")
        print(f"mercury pull failed: could not write outputs:"
              f" {type(exc).__name__}: {detail}", file=sys.stderr)
        return 1
    for name in outputs:
        os.replace(tmp_paths[name], os.path.join(out_dir, name))
    return 0


def main():
    sys.exit(run(sys.argv[1:], os.environ, _http_get_json))


if __name__ == "__main__":
    main()
