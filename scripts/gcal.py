#!/usr/bin/env python3
"""Access to personal Google Calendars (no Claude connector required).

Reads work across every account authorized via scripts/google_auth.py, merging
events from all of their calendars newest-first. Use --account to pick one.
Writes (add/delete) require exactly one --account.

    scripts/gcal.py agenda --days 7
    scripts/gcal.py today
    scripts/gcal.py calendars
    scripts/gcal.py search "dentist" --days 90
    scripts/gcal.py add "Nick's Grad Party" --account stevenharrison \
        --calendar "Hannah Svenson" --start "2026-08-22 16:00" --end "2026-08-22 19:00" \
        --location "1 Norman Ln, Philadelphia, PA 19118" --description "..."
    scripts/gcal.py delete <event-id> --account stevenharrison --calendar "Hannah Svenson"
Add --json for machine-readable output.
"""
import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import google_common as g  # noqa: E402

g.reexec_in_venv()


def _now():
    return datetime.now(timezone.utc)


def _rfc3339(dt):
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _event_start(ev):
    s = ev.get("start", {})
    return s.get("dateTime") or s.get("date") or ""


def _fmt_when(ev):
    s = ev.get("start", {})
    if "date" in s:  # all-day event
        return f"{s['date']} (all day)"
    dt = datetime.fromisoformat(s["dateTime"]).astimezone()
    return dt.strftime("%Y-%m-%d %H:%M")


def _list_calendars(email):
    svc = g.service("calendar", "v3", email)
    return svc.calendarList().list().execute().get("items", [])


def _cal_name(cal):
    return cal.get("summaryOverride") or cal.get("summary", "")


def _resolve_calendar(email, selector):
    """Return (calendarId, name, timeZone) for the calendar on `email` whose name
    contains `selector` (case-insensitive). Defaults to the primary calendar when
    `selector` is falsy. Exits on zero or multiple matches so a write never lands
    on the wrong calendar."""
    cals = _list_calendars(email)
    if not selector:
        for cal in cals:
            if cal.get("primary"):
                return cal["id"], _cal_name(cal), cal.get("timeZone")
        sys.exit(f"No primary calendar found for {email}.")
    matches = [c for c in cals if selector.lower() in _cal_name(c).lower()]
    if not matches:
        names = ", ".join(_cal_name(c) for c in cals)
        sys.exit(f"No calendar on {email} matches '{selector}'. Available: {names}")
    if len(matches) > 1:
        names = ", ".join(_cal_name(c) for c in matches)
        sys.exit(f"'{selector}' is ambiguous on {email} (matches: {names}). Be more specific.")
    c = matches[0]
    return c["id"], _cal_name(c), c.get("timeZone")


def _parse_dt(s):
    """Parse an event boundary. Returns (value, is_all_day):
      'YYYY-MM-DD'            -> (date-string, True)   all-day
      'YYYY-MM-DD HH:MM'      -> (naive datetime, False)"""
    s = s.strip()
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(s, fmt), False
        except ValueError:
            pass
    try:
        datetime.strptime(s, "%Y-%m-%d")
        return s, True
    except ValueError:
        sys.exit(f"Could not parse '{s}'. Use 'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM'.")


def _collect(accounts, time_min, time_max, query, limit):
    events = []
    for email in accounts:
        try:
            svc = g.service("calendar", "v3", email)
            cals = svc.calendarList().list().execute().get("items", [])
        except SystemExit:
            raise
        except Exception as e:
            # One broken account must not kill the merged view.
            print(f"warning: skipping {email}: {type(e).__name__}: "
                  f"{str(e).splitlines()[0][:100]} (re-auth: scripts/google_auth.py add)",
                  file=sys.stderr)
            continue
        for cal in cals:
            params = dict(calendarId=cal["id"], singleEvents=True, orderBy="startTime",
                          maxResults=limit, timeMin=_rfc3339(time_min))
            if time_max:
                params["timeMax"] = _rfc3339(time_max)
            if query:
                params["q"] = query
            for ev in svc.events().list(**params).execute().get("items", []):
                events.append({
                    "account": email,
                    "calendar": cal.get("summaryOverride") or cal.get("summary", ""),
                    "when": _fmt_when(ev),
                    "start": _event_start(ev),
                    "title": ev.get("summary", "(no title)"),
                    "location": ev.get("location", ""),
                    "id": ev.get("id", ""),
                })
    events.sort(key=lambda e: e["start"])
    return events[:limit] if limit else events


def _print(events, as_json, multi):
    if as_json:
        print(json.dumps(events, ensure_ascii=False, indent=2))
        return
    if not events:
        print("No events.", file=sys.stderr)
        return
    for e in events:
        tag = f"[{e['account']}] " if multi else ""
        loc = f"  @ {e['location']}" if e["location"] else ""
        print(f"{e['when']:>18}  {tag}{e['title']}{loc}")
        if e["calendar"]:
            print(f"                    ({e['calendar']})")


def cmd_agenda(args):
    accts = g.resolve_accounts(args.account)
    events = _collect(accts, _now(), _now() + timedelta(days=args.days or 7),
                      None, args.limit)
    _print(events, args.json, len(accts) > 1)


def cmd_today(args):
    accts = g.resolve_accounts(args.account)
    start = _now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
    events = _collect(accts, start, start + timedelta(days=1), None, args.limit)
    _print(events, args.json, len(accts) > 1)


def cmd_search(args):
    accts = g.resolve_accounts(args.account)
    # Search a wide window centered on now unless --days narrows the future span.
    events = _collect(accts, _now() - timedelta(days=args.days or 365),
                      _now() + timedelta(days=args.days or 365), args.query, args.limit)
    _print(events, args.json, len(accts) > 1)


def cmd_calendars(args):
    accts = g.resolve_accounts(args.account)
    rows = []
    for email in accts:
        for cal in _list_calendars(email):
            rows.append({"account": email,
                         "calendar": cal.get("summaryOverride") or cal.get("summary", ""),
                         "id": cal["id"], "primary": cal.get("primary", False)})
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return
    for r in rows:
        star = "* " if r["primary"] else "  "
        print(f"{star}[{r['account']}] {r['calendar']}")


def _one_account(args, verb):
    accts = g.resolve_accounts(args.account)
    if len(accts) != 1:
        sys.exit(f"'{verb}' writes to one calendar, so it needs exactly one account.\n"
                 f"Pass --account to narrow (matched: {', '.join(accts)}).")
    return accts[0]


def cmd_add(args):
    email = _one_account(args, "add")
    svc = g.service("calendar", "v3", email)
    cal_id, cal_name, cal_tz = _resolve_calendar(email, args.calendar)
    tz = args.tz or cal_tz or "UTC"

    start_val, all_day = _parse_dt(args.start)
    end_val, end_all_day = (_parse_dt(args.end) if args.end else (None, all_day))
    if end_val is not None and end_all_day != all_day:
        sys.exit("--start and --end must both be dates or both be date-times.")

    body = {"summary": args.title}
    if args.location:
        body["location"] = args.location
    if args.description:
        body["description"] = args.description

    if all_day:
        # Google treats an all-day end date as exclusive; default to the next day.
        if end_val is None:
            end_val = (datetime.strptime(start_val, "%Y-%m-%d")
                       + timedelta(days=1)).strftime("%Y-%m-%d")
        body["start"] = {"date": start_val}
        body["end"] = {"date": end_val}
    else:
        if end_val is None:
            end_val = start_val + timedelta(hours=1)
        body["start"] = {"dateTime": start_val.isoformat(timespec="seconds"), "timeZone": tz}
        body["end"] = {"dateTime": end_val.isoformat(timespec="seconds"), "timeZone": tz}

    created = svc.events().insert(calendarId=cal_id, body=body).execute()
    if args.json:
        print(json.dumps({"id": created["id"], "account": email, "calendar": cal_name,
                          "htmlLink": created.get("htmlLink", "")},
                         ensure_ascii=False, indent=2))
        return
    print(f"✓ Created '{created.get('summary')}' on [{email}] {cal_name}")
    print(f"    {_fmt_when(created)}  id: {created['id']}")
    if created.get("htmlLink"):
        print(f"    {created['htmlLink']}")


def cmd_delete(args):
    email = _one_account(args, "delete")
    svc = g.service("calendar", "v3", email)
    cal_id, cal_name, _ = _resolve_calendar(email, args.calendar)
    try:
        ev = svc.events().get(calendarId=cal_id, eventId=args.event_id).execute()
    except Exception as e:
        sys.exit(f"Could not find event {args.event_id} on [{email}] {cal_name}: "
                 f"{str(e).splitlines()[0]}")
    svc.events().delete(calendarId=cal_id, eventId=args.event_id).execute()
    print(f"✓ Deleted '{ev.get('summary', '(no title)')}' ({_fmt_when(ev)}) "
          f"from [{email}] {cal_name}")


def main():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--account", help="substring of an account email; default all")
    common.add_argument("--limit", type=int, default=50)
    common.add_argument("--json", action="store_true")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("agenda", parents=[common], help="upcoming events")
    s.add_argument("--days", type=int, default=7); s.set_defaults(func=cmd_agenda)
    sub.add_parser("today", parents=[common], help="today's events").set_defaults(func=cmd_today)
    s = sub.add_parser("search", parents=[common], help="search events by keyword")
    s.add_argument("query")
    s.add_argument("--days", type=int, default=0, help="+/- window in days (default 365)")
    s.set_defaults(func=cmd_search)
    sub.add_parser("calendars", parents=[common],
                   help="list calendars across accounts").set_defaults(func=cmd_calendars)

    a = sub.add_parser("add", parents=[common], help="create an event (one --account)")
    a.add_argument("title")
    a.add_argument("--calendar", help="substring of the target calendar name (default: primary)")
    a.add_argument("--start", required=True,
                   help="'YYYY-MM-DD' (all-day) or 'YYYY-MM-DD HH:MM'")
    a.add_argument("--end", help="same format as --start; default +1h (timed) / +1 day (all-day)")
    a.add_argument("--location")
    a.add_argument("--description")
    a.add_argument("--tz", help="IANA tz for timed events (default: the calendar's own tz)")
    a.set_defaults(func=cmd_add)

    d = sub.add_parser("delete", parents=[common], help="delete an event by id (one --account)")
    d.add_argument("event_id")
    d.add_argument("--calendar", help="substring of the calendar the event is on (default: primary)")
    d.set_defaults(func=cmd_delete)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
