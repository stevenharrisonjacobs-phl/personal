#!/usr/bin/env python3
"""Read-only access to personal Gmail accounts (no Claude connector required).

Works across every account authorized via scripts/google_auth.py. By default it
queries all of them and merges results newest-first; use --account to pick one.

    scripts/gmail.py recent --limit 20
    scripts/gmail.py unread
    scripts/gmail.py search "from:amazon subject:order" --limit 15
    scripts/gmail.py from "mom@example.com" --days 30
    scripts/gmail.py read <message-id> --account steve.personal
    scripts/gmail.py draft --account steve.personal --to a@b.com --subject Hi --body "..."
Drafting only creates a Gmail draft for you to review and send; it never sends.
Add --json for machine-readable output.
"""
import argparse
import base64
import html
import json
import os
import re
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import google_common as g  # noqa: E402

g.reexec_in_venv()


def _header(msg, name):
    for h in msg.get("payload", {}).get("headers", []):
        if h["name"].lower() == name.lower():
            return h["value"]
    return ""


def _clean(text):
    """Decode HTML entities and strip the invisible padding senders inject into
    preview text, so snippets/subjects read cleanly in the terminal."""
    text = html.unescape(text or "")
    # Remove zero-width and other non-printing filler, then collapse whitespace.
    text = re.sub(r"[­͏​-‏  ﻿]", "", text)
    return re.sub(r"\s+", " ", text).strip()


def _fmt_date(internal_date_ms):
    dt = datetime.fromtimestamp(int(internal_date_ms) / 1000, tz=timezone.utc).astimezone()
    return dt.strftime("%Y-%m-%d %H:%M")


def _collect(accounts, query, limit):
    """Fetch up to `limit` message headers per account matching `query`."""
    items = []
    for email in accounts:
        try:
            svc = g.service("gmail", "v1", email)
            resp = svc.users().messages().list(
                userId="me", q=query or "", maxResults=limit).execute()
        except SystemExit:
            raise
        except Exception as e:
            # One broken account (expired/stale token) must not kill the merged
            # view — warn and keep going with the rest.
            print(f"warning: skipping {email}: {type(e).__name__}: "
                  f"{str(e).splitlines()[0][:100]} (re-auth: scripts/google_auth.py add)",
                  file=sys.stderr)
            continue
        for ref in resp.get("messages", []):
            msg = svc.users().messages().get(
                userId="me", id=ref["id"], format="metadata",
                metadataHeaders=["From", "Subject", "Date"]).execute()
            items.append({
                "account": email,
                "id": msg["id"],
                "ts": int(msg["internalDate"]),
                "date": _fmt_date(msg["internalDate"]),
                "from": _clean(_header(msg, "From")),
                "subject": _clean(_header(msg, "Subject")) or "(no subject)",
                "snippet": _clean(msg.get("snippet", "")),
                "unread": "UNREAD" in msg.get("labelIds", []),
            })
    items.sort(key=lambda x: x["ts"], reverse=True)
    return items[:limit]


def _print_list(items, as_json, multi):
    if as_json:
        print(json.dumps(items, ensure_ascii=False, indent=2))
        return
    if not items:
        print("No messages.", file=sys.stderr)
        return
    for it in items:
        acct = f"[{it['account']}] " if multi else ""
        flag = "● " if it["unread"] else "  "
        print(f"{flag}{it['date']}  {acct}{it['from']}")
        print(f"    {it['subject']}")
        if it["snippet"]:
            print(f"    {it['snippet'][:160]}")
        print(f"    id: {it['id']}")


def _decode_body(payload):
    """Walk a message payload and return the best text body (prefer text/plain)."""
    def walk(part):
        mime = part.get("mimeType", "")
        data = part.get("body", {}).get("data")
        if mime == "text/plain" and data:
            return base64.urlsafe_b64decode(data).decode("utf-8", "replace")
        for sub in part.get("parts", []):
            found = walk(sub)
            if found:
                return found
        if mime == "text/html" and data:  # fallback if no plain part exists
            return base64.urlsafe_b64decode(data).decode("utf-8", "replace")
        return None
    return walk(payload) or ""


def cmd_recent(args):
    items = _collect(g.resolve_accounts(args.account), _apply_days("", args.days), args.limit)
    _print_list(items, args.json, len(g.resolve_accounts(args.account)) > 1)


def cmd_unread(args):
    items = _collect(g.resolve_accounts(args.account),
                     _apply_days("is:unread", args.days), args.limit)
    _print_list(items, args.json, len(g.resolve_accounts(args.account)) > 1)


def cmd_search(args):
    items = _collect(g.resolve_accounts(args.account),
                     _apply_days(args.query, args.days), args.limit)
    _print_list(items, args.json, len(g.resolve_accounts(args.account)) > 1)


def cmd_from(args):
    items = _collect(g.resolve_accounts(args.account),
                     _apply_days(f"from:{args.sender}", args.days), args.limit)
    _print_list(items, args.json, len(g.resolve_accounts(args.account)) > 1)


def cmd_read(args):
    # A message id belongs to exactly one account; try each authorized one.
    for email in g.resolve_accounts(args.account):
        svc = g.service("gmail", "v1", email)
        try:
            msg = svc.users().messages().get(userId="me", id=args.id, format="full").execute()
        except Exception:
            continue
        body = _decode_body(msg["payload"])
        if args.json:
            print(json.dumps({
                "account": email, "id": msg["id"], "date": _fmt_date(msg["internalDate"]),
                "from": _header(msg, "From"), "to": _header(msg, "To"),
                "subject": _header(msg, "Subject"), "body": body,
            }, ensure_ascii=False, indent=2))
        else:
            print(f"Account: {email}")
            print(f"Date:    {_fmt_date(msg['internalDate'])}")
            print(f"From:    {_header(msg, 'From')}")
            print(f"To:      {_header(msg, 'To')}")
            print(f"Subject: {_header(msg, 'Subject')}")
            print("-" * 60)
            print(body.strip())
        return
    sys.exit(f"Message {args.id} not found in any authorized account.")


def cmd_draft(args):
    """Create a Gmail draft in one account. Never sends — you review and send
    it yourself from Gmail. Body comes from --body or stdin."""
    from email.mime.text import MIMEText

    accts = g.resolve_accounts(args.account)
    if len(accts) != 1:
        sys.exit("Drafting needs exactly one sender. Pass --account <email substring>. "
                 f"Authorized: {', '.join(accts)}")
    sender = accts[0]
    body = args.body if args.body is not None else sys.stdin.read()
    msg = MIMEText(body)
    msg["To"] = args.to
    if args.cc:
        msg["Cc"] = args.cc
    msg["Subject"] = args.subject or ""
    raw = base64.urlsafe_b64encode(msg.as_bytes()).decode()
    svc = g.service("gmail", "v1", sender)
    draft = svc.users().drafts().create(
        userId="me", body={"message": {"raw": raw}}).execute()
    if args.json:
        print(json.dumps({"account": sender, "draft_id": draft["id"],
                          "to": args.to, "subject": args.subject}, indent=2))
    else:
        print(f"✓ Draft created in {sender} (id {draft['id']}).")
        print(f"  To: {args.to}   Subject: {args.subject or '(none)'}")
        print("  Open Gmail → Drafts to review and send. Nothing was sent.")


def _apply_days(query, days):
    """Append Gmail's newer_than: operator when --days is set."""
    if days:
        return (query + f" newer_than:{days}d").strip()
    return query


def main():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--account", help="substring of an account email; default all")
    common.add_argument("--limit", type=int, default=20)
    common.add_argument("--days", type=int, default=0, help="only mail from the last N days")
    common.add_argument("--json", action="store_true")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("recent", parents=[common], help="most recent mail").set_defaults(func=cmd_recent)
    sub.add_parser("unread", parents=[common], help="unread mail").set_defaults(func=cmd_unread)
    s = sub.add_parser("search", parents=[common], help="Gmail search query")
    s.add_argument("query"); s.set_defaults(func=cmd_search)
    s = sub.add_parser("from", parents=[common], help="mail from a sender")
    s.add_argument("sender"); s.set_defaults(func=cmd_from)
    s = sub.add_parser("read", parents=[common], help="full body of one message")
    s.add_argument("id"); s.set_defaults(func=cmd_read)
    s = sub.add_parser("draft", parents=[common],
                       help="create a Gmail draft (never sends)")
    s.add_argument("--to", required=True)
    s.add_argument("--subject", default="")
    s.add_argument("--cc")
    s.add_argument("--body", help="body text; if omitted, read from stdin")
    s.set_defaults(func=cmd_draft)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
