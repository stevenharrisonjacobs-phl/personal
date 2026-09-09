#!/usr/bin/env python3
"""mercury_pull.py — deterministic Mercury REST fetch for the daily spend
check-in. Pulls the account list plus every account's transactions for BOTH
the requested window and the week-prior baseline window (start-7d..end-7d),
and writes the raw JSON into --out. NO classification, NO filtering beyond
the posted-date window params — the agent applies counting rules separately.

Auth: MERCURY_API_TOKEN as a Bearer token, unless MERCURY_AUTH=proxy (the
platform proxy injects credentials; no local Authorization header is built
and the missing-token guard is suppressed).

Failure discipline: any HTTP or network error → nonzero exit with ONE stderr
line naming the failure (401 vs network), and NO output files — everything is
fetched into memory first and written only after all pulls succeed, so a
partial run never leaves misleading files behind.

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
from datetime import datetime, timedelta
from urllib.parse import urlencode, urlparse

from collector_common import _http_get_json, parse_iso

MERCURY_API = "https://api.mercury.com/api/v1"
DEFAULT_OUT = ".context/checkin"
USAGE = "usage: mercury_pull.py --start <utc-ts> --end <utc-ts> [--out DIR]"
PAGE_LIMIT = 500
MAX_PAGES = 50  # defensive cap; a window should never come close


# ---- pure helpers -----------------------------------------------------------

def iso_z(t: datetime) -> str:
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def window_params(start_iso: str, end_iso: str) -> dict:
    """Posted-date (YYYY-MM-DD) params for the requested window and the
    week-prior baseline window, plus that baseline's exact timestamps
    ("prev_ts") for the output JSON."""
    start, end = parse_iso(start_iso), parse_iso(end_iso)
    prev_start, prev_end = start - timedelta(days=7), end - timedelta(days=7)
    return {
        "window": (start.date().isoformat(), end.date().isoformat()),
        "prev": (prev_start.date().isoformat(), prev_end.date().isoformat()),
        "prev_ts": (prev_start, prev_end),
    }


def transactions_url(account_id: str, posted_start: str, posted_end: str,
                     limit: int, offset: int) -> str:
    query = urlencode({"limit": limit, "offset": offset,
                       "start": posted_start, "end": posted_end})
    return f"{MERCURY_API}/account/{account_id}/transactions?{query}"


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

def fetch_transactions(http_get, headers, account_id, posted_start, posted_end):
    """One account, one window, paginated defensively (limit/offset; the API's
    paging fields are handled if present, single page assumed if absent)."""
    collected = []
    offset = 0
    for _ in range(MAX_PAGES):
        data = http_get(transactions_url(account_id, posted_start, posted_end,
                                         PAGE_LIMIT, offset), headers)
        page = data.get("transactions") or []
        collected.extend(page)
        total = data.get("total")
        if not page or total is None or len(collected) >= total:
            break
        offset += len(page)
    return collected


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

    prev_start, prev_end = params["prev_ts"]
    # Fetch EVERYTHING before writing anything: a failure mid-pull must not
    # leave partial output files behind.
    try:
        accounts_raw = http_get(f"{MERCURY_API}/accounts", headers)
        window_txns, prev_txns = {}, {}
        for account in accounts_raw.get("accounts") or []:
            account_id = account.get("id")
            if not account_id:
                continue
            window_txns[account_id] = fetch_transactions(
                http_get, headers, account_id, *params["window"])
            prev_txns[account_id] = fetch_transactions(
                http_get, headers, account_id, *params["prev"])
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
                       "posted_start": params["window"][0],
                       "posted_end": params["window"][1]},
            "accounts": window_txns,
        },
        "transactions-prev.json": {
            "window": {"start": iso_z(prev_start), "end": iso_z(prev_end),
                       "posted_start": params["prev"][0],
                       "posted_end": params["prev"][1]},
            "accounts": prev_txns,
        },
    }
    for name, payload in outputs.items():
        with open(os.path.join(out_dir, name), "w") as f:
            json.dump(payload, f, indent=1)
    return 0


def main():
    sys.exit(run(sys.argv[1:], os.environ, _http_get_json))


if __name__ == "__main__":
    main()
