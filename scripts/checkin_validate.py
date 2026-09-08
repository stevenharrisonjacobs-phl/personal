#!/usr/bin/env python3
"""Payload validation for the daily spend check-in writer.

Called by scripts/checkin-write.sh (the ONLY writer for
finance.checkin_reports) and unit-tested offline by
tests/test_checkin_validate.py. Every refusal names its reason; the writer
refuses rather than landing a doubtful row.

Contract enforced here:
  * Timestamps are parsed (any RFC3339/ISO-8601 UTC form the regex accepts)
    and compared chronologically — never as raw strings — then written back
    in ONE canonical form (%Y-%m-%dT%H:%M:%SZ) so the bash-side string
    equality against BigQuery's FORMAT_TIMESTAMP output is sound.
  * window_start must equal the consumed checkpoint (contiguity); a payload
    with no checkpoint (first run) is exempt.
  * All four sources and all four headline keys must be present; each source
    carries status ok|failed; a failed source has total null; at least one
    source must be ok for a success row to exist at all.
  * Content bounds apply to report_md AND the serialized sources/totals JSON
    (the door redacts by column name only, so nested free text ships
    verbatim unless it is stopped here).
  * Headline totals must equal the per-source totals they summarize.
"""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone

TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|\+00:?00)$")
REPORT_MD_CAP = 100_000
JSON_CAP = 20_000
DIGIT_RUN = re.compile(r"\d{9,}")
SOURCES = ("mirror", "vantage", "live_costs", "mercury")
HEADLINES = {"personal_cash": "mirror", "mercury_cash": "mercury",
             "cloud_billed": "vantage", "cloud_live": "live_costs"}


def parse_ts(value: str) -> datetime:
    return datetime.fromisoformat(
        str(value).replace("Z", "+00:00").replace(" ", "T")
    ).astimezone(timezone.utc)


def canonical(value: str) -> str:
    return parse_ts(value).strftime("%Y-%m-%dT%H:%M:%SZ")


def validate(p: dict) -> tuple[dict, list[str]]:
    """Return (canonical param dict, errors). Params are valid only when
    errors is empty."""
    errors: list[str] = []

    for field in ("run_ts", "window_start", "window_end", "sources", "totals", "report_md"):
        if field not in p:
            errors.append(f"missing field: {field}")
    if errors:
        return {}, errors

    for field in ("run_ts", "window_start", "window_end"):
        if not TS_RE.match(str(p[field])):
            errors.append(f"{field} is not a UTC timestamp: {p[field]}")
    ckpt = p.get("consumed_checkpoint")
    if ckpt and not TS_RE.match(str(ckpt)):
        errors.append("consumed_checkpoint is not a UTC timestamp")
    if errors:
        return {}, errors

    start, end, run_ts = parse_ts(p["window_start"]), parse_ts(p["window_end"]), parse_ts(p["run_ts"])
    if end <= start:
        errors.append("window_end must be after window_start")
    if run_ts < end:
        errors.append("run_ts must be at or after window_end")
    if ckpt and parse_ts(ckpt) != start:
        errors.append(
            f"window_start ({p['window_start']}) must equal the consumed checkpoint "
            f"({ckpt}) — a gap or overlap breaks window contiguity")

    sources, totals = p["sources"], p["totals"]
    if not isinstance(sources, dict) or not isinstance(totals, dict):
        return {}, ["sources and totals must be objects"]
    for name in SOURCES:
        s = sources.get(name)
        if not isinstance(s, dict):
            errors.append(f"sources.{name} missing")
            continue
        if s.get("status") not in ("ok", "failed"):
            errors.append(f"sources.{name}.status must be ok or failed")
        if s.get("status") == "failed" and s.get("total") is not None:
            errors.append(f"sources.{name} failed but carries a total")
    for headline in HEADLINES:
        if headline not in totals:
            errors.append(f"totals.{headline} missing")
    if not any(isinstance(sources.get(n), dict) and sources[n].get("status") == "ok"
               for n in SOURCES):
        errors.append("no source succeeded — record a failed run, not a success row")

    md = p["report_md"]
    if len(md) > REPORT_MD_CAP:
        errors.append(f"report_md over length cap: {len(md)} > {REPORT_MD_CAP}")
    sources_json, totals_json = json.dumps(sources), json.dumps(totals)
    if len(sources_json) > JSON_CAP:
        errors.append(f"sources JSON over length cap: {len(sources_json)} > {JSON_CAP}")
    for label, text in (("report_md", md), ("sources", sources_json), ("totals", totals_json)):
        runs = DIGIT_RUN.findall(text)
        if runs:
            errors.append(f"{label} contains account-number-like digit runs: {runs[:3]}")

    for headline, source in HEADLINES.items():
        h = totals.get(headline)
        s = (sources.get(source) or {}).get("total")
        if h is None and s is None:
            continue
        if (h is None) != (s is None):
            errors.append(f"totals.{headline} and sources.{source}.total disagree on presence")
        elif abs(float(h) - float(s)) > 0.01:
            errors.append(f"totals.{headline}={h} != sources.{source}.total={s}")

    if errors:
        return {}, errors
    return {
        "run_ts": canonical(p["run_ts"]),
        "consumed_checkpoint": canonical(ckpt) if ckpt else "none",
        "window_start": canonical(p["window_start"]),
        "window_end": canonical(p["window_end"]),
        "sources": sources_json,
        "totals": totals_json,
        "report_md": md,
    }, []


def main() -> int:
    payload_path, out_dir = sys.argv[1], sys.argv[2]
    with open(payload_path) as f:
        p = json.load(f)
    params, errors = validate(p)
    if errors:
        print("checkin-write: refused: " + "; ".join(errors), file=sys.stderr)
        return 1
    for name, value in params.items():
        with open(f"{out_dir}/{name}", "w") as f:
            f.write(value)
    return 0


if __name__ == "__main__":
    sys.exit(main())
