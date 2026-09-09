"""Helpers shared by the spend check-in collector scripts (mercury_pull.py,
spend_checkin_costs.py): ISO-8601 parsing and the stdlib-only HTTP GET."""

from __future__ import annotations

import json
import urllib.request
from datetime import datetime


def parse_iso(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def _http_get_json(url, headers, timeout=60):
    req = urllib.request.Request(url, headers=dict(headers))
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))
