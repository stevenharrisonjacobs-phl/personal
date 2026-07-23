#!/usr/bin/env python3
"""Delta-first weather: is it getting better or worse than it said before?

Weather apps show you today's forecast. They never show you how the forecast
*changed* — that Saturday quietly dropped from 75° to 64° and rain climbed
10%→70% over three days. That signal only exists if you snapshot the forecast
every day and diff it. You cannot backfill it: the API only ever returns the
*current* forecast, so the history starts the day you start capturing.

    scripts/weather.py snapshot          # fetch current forecast, append to the DB (run 2x/day via cron)
    scripts/weather.py brief             # the delta-first briefing (reads the DB)
    scripts/weather.py brief --refresh   # snapshot first, then brief (always current)
    scripts/weather.py history 2026-07-26   # the full revision trail for one target day
    scripts/weather.py locations         # known locations

Source: Open-Meteo (free, no API key). Store: local SQLite, append-only,
stdlib-only — nothing to install, so the capture job never breaks. Add --json
to snapshot/brief/history for machine-readable output.
"""
import argparse
import json
import os
import sqlite3
import sys
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta

# The snapshot history is append-only and CANNOT be backfilled, so it must
# outlive any single git checkout / Conductor worktree. It lives in the home
# dir, not the repo. Override with COLUMBUS_WEATHER_DB.
DB_PATH = os.environ.get("COLUMBUS_WEATHER_DB") or \
    os.path.expanduser("~/.columbus/weather.db")

# Known locations. Add your own; --lat/--lon/--label override for ad-hoc places.
LOCATIONS = {
    "philadelphia": (39.9526, -75.1652, "Philadelphia"),
}
DEFAULT_LOCATION = "philadelphia"

# What "nice" means — tunable. Temp uses the apparent (feels-like) high, so both
# a muggy 95° and a raw 40° score as worse; a cooler day in a heat wave scores
# as *better*. Bump ideal_high down if you like it cold.
PREFS = {
    "ideal_high": 76.0,   # feels-like high (°F) that scores perfect
    "temp_weight": 0.04,  # penalty per (°F from ideal)^2  → 12° off ≈ 5.8 pts
    "rain_prob_weight": 0.15,   # penalty per % chance      → 70% ≈ 10.5 pts
    "rain_amt_weight": 8.0,     # penalty per inch
    "wind_free": 15.0,    # mph tolerated before it counts
    "wind_weight": 0.4,   # penalty per mph over wind_free
}
SIMILAR = 3.0  # |niceness delta| below this reads as "about the same"

# WMO weather codes → (emoji, short label). https://open-meteo.com/en/docs
WMO = {
    0: ("☀️", "clear"), 1: ("🌤️", "mostly clear"), 2: ("⛅", "partly cloudy"),
    3: ("☁️", "overcast"), 45: ("🌫️", "fog"), 48: ("🌫️", "rime fog"),
    51: ("🌦️", "light drizzle"), 53: ("🌦️", "drizzle"), 55: ("🌦️", "heavy drizzle"),
    56: ("🌧️", "freezing drizzle"), 57: ("🌧️", "freezing drizzle"),
    61: ("🌦️", "light rain"), 63: ("🌧️", "rain"), 65: ("🌧️", "heavy rain"),
    66: ("🌧️", "freezing rain"), 67: ("🌧️", "freezing rain"),
    71: ("🌨️", "light snow"), 73: ("🌨️", "snow"), 75: ("❄️", "heavy snow"),
    77: ("🌨️", "snow grains"), 80: ("🌦️", "light showers"), 81: ("🌧️", "showers"),
    82: ("⛈️", "violent showers"), 85: ("🌨️", "snow showers"), 86: ("❄️", "heavy snow showers"),
    95: ("⛈️", "thunderstorm"), 96: ("⛈️", "storm w/ hail"), 99: ("⛈️", "storm w/ hail"),
}

METRICS = ["weather_code", "t_high", "t_low", "feels_high", "feels_low",
           "precip_prob", "precip_in", "wind_max"]


# ---------------------------------------------------------------------------
# storage
# ---------------------------------------------------------------------------
def _db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("""
        CREATE TABLE IF NOT EXISTS forecasts (
            captured_at  TEXT NOT NULL,   -- ISO local timestamp of the snapshot
            location     TEXT NOT NULL,   -- location key
            lat          REAL, lon REAL,
            target_date  TEXT NOT NULL,   -- the day being forecast (YYYY-MM-DD)
            weather_code INTEGER,
            t_high REAL, t_low REAL,
            feels_high REAL, feels_low REAL,
            precip_prob REAL, precip_in REAL, wind_max REAL,
            PRIMARY KEY (captured_at, location, target_date)
        )""")
    conn.execute("CREATE INDEX IF NOT EXISTS ix_target ON forecasts(location, target_date, captured_at)")
    return conn


# ---------------------------------------------------------------------------
# fetch
# ---------------------------------------------------------------------------
def _resolve_location(args):
    if args.lat is not None and args.lon is not None:
        return (args.lat, args.lon, args.label or f"{args.lat},{args.lon}",
                args.label or f"{args.lat},{args.lon}")
    key = (args.location or DEFAULT_LOCATION).lower()
    if key not in LOCATIONS:
        sys.exit(f"Unknown location '{key}'. Known: {', '.join(LOCATIONS)} "
                 f"(or pass --lat/--lon).")
    lat, lon, label = LOCATIONS[key]
    return lat, lon, key, label


def fetch_forecast(lat, lon):
    """Return list of daily dicts (yesterday .. +15) from Open-Meteo."""
    daily = ["weather_code", "temperature_2m_max", "temperature_2m_min",
             "apparent_temperature_max", "apparent_temperature_min",
             "precipitation_probability_max", "precipitation_sum", "wind_speed_10m_max"]
    q = urllib.parse.urlencode({
        "latitude": lat, "longitude": lon, "daily": ",".join(daily),
        "temperature_unit": "fahrenheit", "wind_speed_unit": "mph",
        "precipitation_unit": "inch", "timezone": "auto",
        "past_days": 1, "forecast_days": 16,
    })
    url = f"https://api.open-meteo.com/v1/forecast?{q}"
    req = urllib.request.Request(url, headers={"User-Agent": "columbus-weather/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            data = json.load(r)
    except Exception as e:
        sys.exit(f"Open-Meteo request failed: {e}")
    d = data["daily"]
    rows = []
    for i, day in enumerate(d["time"]):
        rows.append({
            "target_date": day,
            "weather_code": d["weather_code"][i],
            "t_high": d["temperature_2m_max"][i],
            "t_low": d["temperature_2m_min"][i],
            "feels_high": d["apparent_temperature_max"][i],
            "feels_low": d["apparent_temperature_min"][i],
            "precip_prob": d["precipitation_probability_max"][i],
            "precip_in": d["precipitation_sum"][i],
            "wind_max": d["wind_speed_10m_max"][i],
        })
    return rows


def cmd_snapshot(args):
    lat, lon, key, label = _resolve_location(args)
    rows = fetch_forecast(lat, lon)
    captured_at = datetime.now().replace(microsecond=0).isoformat()
    conn = _db()
    with conn:
        for r in rows:
            conn.execute(
                "INSERT OR REPLACE INTO forecasts (captured_at, location, lat, lon, "
                "target_date, weather_code, t_high, t_low, feels_high, feels_low, "
                "precip_prob, precip_in, wind_max) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (captured_at, key, lat, lon, r["target_date"], r["weather_code"],
                 r["t_high"], r["t_low"], r["feels_high"], r["feels_low"],
                 r["precip_prob"], r["precip_in"], r["wind_max"]))
    n_snaps = conn.execute(
        "SELECT COUNT(DISTINCT captured_at) FROM forecasts WHERE location=?", (key,)).fetchone()[0]
    if args.json:
        print(json.dumps({"captured_at": captured_at, "location": key,
                          "rows": len(rows), "total_snapshots": n_snaps}))
    else:
        # When invoked as the refresh step of `brief`, route the confirmation to
        # stderr so it never pollutes stdout (which may be JSON a caller parses).
        out = sys.stderr if getattr(args, "quiet", False) else sys.stdout
        print(f"✓ Snapshot {captured_at} · {label} · {len(rows)} days stored "
              f"· {n_snaps} snapshot(s) on record", file=out)


# ---------------------------------------------------------------------------
# scoring / deltas
# ---------------------------------------------------------------------------
def niceness(row):
    p = PREFS
    fh = row["feels_high"] if row["feels_high"] is not None else row["t_high"]
    score = 100.0
    if fh is not None:
        score -= ((fh - p["ideal_high"]) ** 2) * p["temp_weight"]
    score -= (row["precip_prob"] or 0) * p["rain_prob_weight"]
    score -= (row["precip_in"] or 0) * p["rain_amt_weight"]
    score -= max(0, (row["wind_max"] or 0) - p["wind_free"]) * p["wind_weight"]
    return score


def verdict(delta):
    if delta > SIMILAR:
        return "↑ better"
    if delta < -SIMILAR:
        return "↓ worse"
    return "→ about the same"


def drivers(old, new):
    """Plain-language phrases for the biggest changes old→new."""
    out = []
    if old["t_high"] is not None and new["t_high"] is not None:
        dh = new["t_high"] - old["t_high"]
        if abs(dh) >= 2:
            out.append(f"{'warmer' if dh > 0 else 'cooler'} {abs(dh):.0f}° "
                       f"({old['t_high']:.0f}°→{new['t_high']:.0f}°)")
    op, np_ = old["precip_prob"] or 0, new["precip_prob"] or 0
    if abs(np_ - op) >= 10:
        out.append(f"rain {'up' if np_ > op else 'down'} {op:.0f}%→{np_:.0f}%")
    ow, nw = old["wind_max"] or 0, new["wind_max"] or 0
    if abs(nw - ow) >= 6:
        out.append(f"wind {'up' if nw > ow else 'down'} {ow:.0f}→{nw:.0f}mph")
    return out


def _tail_run(scores):
    """Length of the consecutive same-direction run at the end of a score series.
    Returns (direction, n_values) where direction is -1/0/+1. n_values>=3 means
    2+ moves the same way = a real trend."""
    if len(scores) < 3:
        return 0, 0
    def sign(x):
        return 1 if x > SIMILAR else (-1 if x < -SIMILAR else 0)
    last = sign(scores[-1] - scores[-2])
    if last == 0:
        return 0, 0
    n = 2
    for i in range(len(scores) - 2, 0, -1):
        if sign(scores[i] - scores[i - 1]) == last:
            n += 1
        else:
            break
    return last, n


def _snapshots(conn, location):
    return [r[0] for r in conn.execute(
        "SELECT DISTINCT captured_at FROM forecasts WHERE location=? ORDER BY captured_at",
        (location,)).fetchall()]


def _row(conn, location, captured_at, target_date):
    return conn.execute(
        "SELECT * FROM forecasts WHERE location=? AND captured_at=? AND target_date=?",
        (location, captured_at, target_date)).fetchone()


# ---------------------------------------------------------------------------
# brief
# ---------------------------------------------------------------------------
def _cond(row):
    emoji, label = WMO.get(row["weather_code"], ("•", "?"))
    return emoji, label


def build_brief(conn, location, label, days):
    snaps = _snapshots(conn, location)
    if not snaps:
        return None
    latest = snaps[-1]
    prev = snaps[-2] if len(snaps) >= 2 else None
    today = date.today().isoformat()
    yesterday = (date.today() - timedelta(days=1)).isoformat()

    out = {"location": label, "captured_at": latest,
           "snapshots_on_record": len(snaps),
           "day_over_day": None, "revisions": [], "outlook": []}

    # today vs yesterday (day-over-day) — both from the latest snapshot
    t_row, y_row = _row(conn, location, latest, today), _row(conn, location, latest, yesterday)
    if t_row and y_row:
        d = niceness(t_row) - niceness(y_row)
        out["day_over_day"] = {"verdict": verdict(d), "drivers": drivers(y_row, t_row),
                               "today": dict(t_row), "yesterday": dict(y_row)}

    # revisions — for each upcoming day, latest snapshot vs the prior one(s)
    for i in range(days):
        d0 = (date.today() + timedelta(days=i)).isoformat()
        cur = _row(conn, location, latest, d0)
        if not cur:
            continue
        emoji, cond = _cond(cur)
        entry = {"date": d0, "emoji": emoji, "cond": cond,
                 "t_high": cur["t_high"], "t_low": cur["t_low"],
                 "precip_prob": cur["precip_prob"], "revised": None, "trend": None}
        if prev:
            pr = _row(conn, location, prev, d0)
            if pr:
                dv = niceness(cur) - niceness(pr)
                if abs(dv) > SIMILAR:
                    entry["revised"] = {"verdict": verdict(dv), "drivers": drivers(pr, cur)}
        # multi-snapshot trend for this day
        series = [_row(conn, location, s, d0) for s in snaps]
        scores = [niceness(r) for r in series if r]
        direction, n = _tail_run(scores)
        if n >= 3:
            highs = [r["t_high"] for r in series if r][-n:]
            probs = [r["precip_prob"] or 0 for r in series if r][-n:]
            entry["trend"] = {
                "direction": "worse" if direction < 0 else "better", "n": n,
                "highs": highs, "probs": probs}
        out["revisions"].append(entry)
    out["outlook"] = out["revisions"][:days]
    return out


def render_brief(b):
    L = []
    L.append(f"Weather — {b['location']} · {datetime.now():%a %b %-d, %-I:%M %p}")
    L.append("")

    dd = b["day_over_day"]
    if dd:
        drv = " — " + ", ".join(dd["drivers"]) if dd["drivers"] else ""
        L.append(f"TODAY vs YESTERDAY:  {dd['verdict']}{drv}")
        L.append("")

    revised = [r for r in b["revisions"] if r.get("revised") or r.get("trend")]
    if b["snapshots_on_record"] < 2:
        L.append("FORECAST REVISIONS:  (starts after the next snapshot — need ≥2 to diff)")
    elif not revised:
        L.append("FORECAST REVISIONS:  none — the forecast held steady since last snapshot")
    else:
        L.append("FORECAST REVISIONS (vs what it said before):")
        for r in revised:
            when = _daylabel(r["date"])
            if r.get("trend"):
                t = r["trend"]
                arrow = "⚠️" if t["direction"] == "worse" else "✓"
                highs = " → ".join(f"{h:.0f}°" for h in t["highs"])
                probs = " → ".join(f"{p:.0f}%" for p in t["probs"])
                L.append(f"  {arrow} {when} trending {t['direction'].upper()} "
                         f"— {t['n']} snapshots running")
                L.append(f"       high {highs}   rain {probs}")
            elif r.get("revised"):
                rv = r["revised"]
                mark = "⚠️" if "worse" in rv["verdict"] else "✓"
                drv = ", ".join(rv["drivers"]) or rv["verdict"]
                L.append(f"  {mark} {when}: {rv['verdict']} — {drv}")
    L.append("")

    # compact outlook line
    cells = []
    for r in b["outlook"]:
        prob = r["precip_prob"]
        wet = "" if not prob or prob < 30 else f" {prob:.0f}%"
        cells.append(f"{_daylabel(r['date'], short=True)} {r['emoji']}{r['t_high']:.0f}{wet}")
    L.append("OUTLOOK:  " + "   ".join(cells))
    return "\n".join(L)


def _daylabel(iso, short=False):
    d = datetime.strptime(iso, "%Y-%m-%d").date()
    today = date.today()
    if d == today:
        return "Today"
    if d == today + timedelta(days=1):
        return "Tomorrow" if not short else "Tmrw"
    return f"{d:%a}" if short else f"{d:%A}"


def cmd_brief(args):
    if args.refresh:
        cmd_snapshot(argparse.Namespace(location=args.location, lat=args.lat,
                                        lon=args.lon, label=args.label,
                                        json=False, quiet=True))
    lat, lon, key, label = _resolve_location(args)
    conn = _db()
    b = build_brief(conn, key, label, args.days)
    if b is None:
        sys.exit("No snapshots yet. Run: scripts/weather.py snapshot")
    if args.json:
        print(json.dumps(b, indent=2))
    else:
        print(render_brief(b))


def cmd_history(args):
    lat, lon, key, label = _resolve_location(args)
    conn = _db()
    rows = conn.execute(
        "SELECT captured_at, weather_code, t_high, t_low, precip_prob, precip_in, wind_max "
        "FROM forecasts WHERE location=? AND target_date=? ORDER BY captured_at",
        (key, args.date)).fetchall()
    if not rows:
        sys.exit(f"No snapshots for {args.date} at {label}.")
    if args.json:
        print(json.dumps([dict(r) for r in rows], indent=2))
        return
    print(f"Revision trail — {label} forecast for {args.date}:")
    print(f"  {'captured':<20} {'cond':<14} {'high':>5} {'low':>5} {'rain%':>6} {'in':>5} {'wind':>5}")
    for r in rows:
        _, cond = WMO.get(r["weather_code"], ("", "?"))
        pp = "" if r["precip_prob"] is None else f"{r['precip_prob']:.0f}"
        print(f"  {r['captured_at']:<20} {cond:<14} {r['t_high']:>4.0f}° {r['t_low']:>4.0f}° "
              f"{pp:>6} {r['precip_in']:>5.2f} {r['wind_max']:>4.0f}")


def cmd_locations(args):
    for k, (lat, lon, label) in LOCATIONS.items():
        star = " (default)" if k == DEFAULT_LOCATION else ""
        print(f"  {k:<16} {label:<20} {lat},{lon}{star}")


# ---------------------------------------------------------------------------
def main():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--location", help=f"location key (default: {DEFAULT_LOCATION})")
    common.add_argument("--lat", type=float, help="ad-hoc latitude (with --lon)")
    common.add_argument("--lon", type=float, help="ad-hoc longitude (with --lat)")
    common.add_argument("--label", help="display name for an ad-hoc --lat/--lon")
    common.add_argument("--json", action="store_true")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("snapshot", parents=[common], help="fetch current forecast, append to DB")
    s.set_defaults(func=cmd_snapshot)

    b = sub.add_parser("brief", parents=[common], help="delta-first briefing")
    b.add_argument("--days", type=int, default=6, help="days of outlook (default 6)")
    b.add_argument("--refresh", action="store_true", help="snapshot first, then brief")
    b.set_defaults(func=cmd_brief)

    h = sub.add_parser("history", parents=[common], help="revision trail for one target day")
    h.add_argument("date", help="target day, YYYY-MM-DD")
    h.set_defaults(func=cmd_history)

    sub.add_parser("locations", parents=[common], help="list known locations").set_defaults(func=cmd_locations)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
