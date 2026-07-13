#!/usr/bin/env python3
"""Read-only access to the local macOS iMessage/SMS store (~/Library/Messages/chat.db).

No connector required: the Messages app keeps every message in a local SQLite
database. On modern macOS the human-readable body is not in the `text` column
(usually NULL) but in an `attributedBody` typedstream blob, so this tool decodes
that blob. Access requires Full Disk Access for the process running this script
(System Settings -> Privacy & Security -> Full Disk Access).

The database is opened read-only and immutable; nothing here ever writes to it.

Examples:
    scripts/imessages.py chats --limit 20
    scripts/imessages.py with "+14155551234" --limit 50
    scripts/imessages.py with "mom" --days 30
    scripts/imessages.py recent --limit 40
    scripts/imessages.py search "dinner reservation" --days 90
Add --json to any command for machine-readable output.
"""
import argparse
import glob
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone

DB = os.path.expanduser("~/Library/Messages/chat.db")
# Apple Cocoa epoch (2001-01-01) offset from Unix epoch, in seconds.
APPLE_EPOCH = 978307200

# macOS Contacts (AddressBook) databases: one per account source, plus a local one.
ADDRESSBOOK_GLOBS = [
    "~/Library/Application Support/AddressBook/Sources/*/AddressBook-v22.abcddb",
    "~/Library/Application Support/AddressBook/AddressBook-v22.abcddb",
]


def _norm_phone(p):
    """Normalize a phone number to its last 10 digits for format-agnostic matching."""
    digits = re.sub(r"\D", "", p or "")
    return digits[-10:] if len(digits) >= 10 else digits


class Contacts:
    """Maps message handles (phone/email) to contact names via macOS AddressBook.

    Loaded lazily and read-only. If Contacts is unavailable the maps stay empty
    and handles simply render as their raw phone/email, so nothing breaks.
    """

    def __init__(self):
        self.by_phone = {}
        self.by_email = {}
        self._loaded = False

    def load(self):
        if self._loaded:
            return
        self._loaded = True
        dbs = []
        for pattern in ADDRESSBOOK_GLOBS:
            dbs.extend(glob.glob(os.path.expanduser(pattern)))
        for db in dbs:
            try:
                con = sqlite3.connect(f"file:{db}?mode=ro&immutable=1", uri=True, timeout=5)
                con.row_factory = sqlite3.Row
                rows = con.execute(
                    """
                    SELECT r.ZFIRSTNAME f, r.ZLASTNAME l, r.ZORGANIZATION o,
                           p.ZFULLNUMBER phone, e.ZADDRESS email
                    FROM ZABCDRECORD r
                    LEFT JOIN ZABCDPHONENUMBER p ON p.ZOWNER = r.Z_PK
                    LEFT JOIN ZABCDEMAILADDRESS e ON e.ZOWNER = r.Z_PK
                    """
                )
                for row in rows:
                    name = " ".join(x for x in (row["f"], row["l"]) if x) or row["o"]
                    if not name:
                        continue
                    if row["phone"]:
                        self.by_phone.setdefault(_norm_phone(row["phone"]), name)
                    if row["email"]:
                        self.by_email.setdefault((row["email"] or "").lower(), name)
                con.close()
            except sqlite3.Error:
                continue

    def name(self, handle):
        """Return the contact name for a handle, or None."""
        if not handle:
            return None
        self.load()
        if "@" in handle:
            return self.by_email.get(handle.lower())
        return self.by_phone.get(_norm_phone(handle))

    def pretty(self, handle):
        """Contact name if known, else the raw handle."""
        return self.name(handle) or handle

    def pretty_chat(self, chat_name):
        """Resolve each member of a possibly comma-joined group-chat label."""
        if not chat_name:
            return chat_name
        # Group labels arrive as comma-joined handles; a real display name has none.
        if "," not in chat_name and not chat_name.startswith(("+", "1")) and "@" not in chat_name:
            return chat_name
        return ", ".join(self.pretty(part.strip()) for part in chat_name.split(","))

    def handles_matching(self, query):
        """Handles (phone/email) whose contact name contains `query`, case-insensitive."""
        self.load()
        q = query.lower()
        out = []
        for phone, name in self.by_phone.items():
            if q in name.lower():
                out.append(phone)
        for email, name in self.by_email.items():
            if q in name.lower():
                out.append(email)
        return out


CONTACTS = Contacts()


def connect():
    if not os.path.exists(DB):
        sys.exit(f"Messages database not found at {DB}")
    try:
        # immutable=1 lets us read even while Messages holds the WAL lock, and
        # guarantees we never touch the file.
        con = sqlite3.connect(f"file:{DB}?mode=ro&immutable=1", uri=True, timeout=10)
        con.execute("select 1 from message limit 1")
        return con
    except sqlite3.OperationalError as e:
        sys.exit(
            f"Cannot read {DB}: {e}\n\n"
            "This almost always means Full Disk Access is not granted to the app "
            "running this script (Terminal / iTerm / the Claude Code host).\n"
            "Grant it in System Settings -> Privacy & Security -> Full Disk Access, "
            "then fully quit and reopen that app."
        )


def apple_ns_to_dt(value):
    """Convert a message.date value to an aware UTC datetime.

    Modern macOS stores nanoseconds since the Cocoa epoch; older rows used
    seconds. Detect by magnitude.
    """
    if not value:
        return None
    seconds = value / 1e9 if value > 1e11 else float(value)
    return datetime.fromtimestamp(seconds + APPLE_EPOCH, tz=timezone.utc)


def decode_attributed_body(blob):
    """Best-effort extraction of the message text from an attributedBody blob.

    The blob is an NSAttributedString serialized as a typedstream. The plain
    string follows an "NSString" marker with a length prefix. This heuristic
    covers the overwhelming majority of messages.
    """
    if not blob:
        return None
    try:
        if b"NSString" not in blob:
            return None
        segment = blob.split(b"NSString", 1)[1]
        # Skip the class/version bookkeeping bytes that precede the length.
        segment = segment[5:]
        marker = segment[0]
        if marker == 0x81:  # 2-byte little-endian length
            length = int.from_bytes(segment[1:3], "little")
            start = 3
        elif marker == 0x82:  # 4-byte little-endian length (very long messages)
            length = int.from_bytes(segment[1:5], "little")
            start = 5
        else:  # single-byte length
            length = marker
            start = 1
        raw = segment[start : start + length]
        return raw.decode("utf-8", errors="replace").strip() or None
    except Exception:
        return None


def body(row):
    """Prefer the plain text column; fall back to decoding attributedBody."""
    if row["text"]:
        return row["text"]
    return decode_attributed_body(row["attributedBody"])


def to_local(dt):
    return dt.astimezone() if dt else None


def print_messages(rows, as_json, show_chat=False):
    out = []
    for r in rows:
        dt = to_local(apple_ns_to_dt(r["date"]))
        sender = "Me" if r["is_from_me"] else CONTACTS.pretty(r["handle"] or "unknown")
        text = body(r) or ("<attachment/no text>" if r["cache_has_attachments"] else "")
        item = {
            "date": dt.isoformat() if dt else None,
            "from": sender,
            "text": text,
        }
        if show_chat:
            item["chat"] = CONTACTS.pretty_chat(r["chat_name"])
        out.append(item)
    if as_json:
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return
    for it in out:
        ts = it["date"][:16].replace("T", " ") if it["date"] else "?"
        prefix = f"[{ts}] "
        # Only show the chat label when it adds info (group chats), not for 1:1s
        # where it would just repeat the sender.
        if show_chat and it.get("chat") and it["chat"] != it["from"]:
            prefix += f"({it['chat']}) "
        print(f"{prefix}{it['from']}: {it['text']}")


# Base SELECT with the joins every message query needs.
MSG_SELECT = """
    SELECT m.ROWID, m.date, m.is_from_me, m.text, m.attributedBody,
           m.cache_has_attachments,
           h.id AS handle,
           c.display_name AS chat_display,
           COALESCE(NULLIF(c.display_name,''), h.id) AS chat_name
    FROM message m
    LEFT JOIN handle h ON m.handle_id = h.ROWID
    LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    LEFT JOIN chat c ON c.ROWID = cmj.chat_id
"""


def cmd_recent(con, args):
    rows = con.execute(
        MSG_SELECT + " ORDER BY m.date DESC LIMIT ?", (args.limit,)
    ).fetchall()
    print_messages(reversed(rows), args.json, show_chat=True)


def cmd_with(con, args):
    """Show a conversation matching a handle (phone/email), chat display name,
    or a contact name resolved through AddressBook."""
    like = f"%{args.who}%"
    clauses = ["h.id LIKE ?", "c.display_name LIKE ?"]
    params = [like, like]
    # Let the query match by contact name, e.g. `with "andrew"`.
    name_handles = CONTACTS.handles_matching(args.who)
    if name_handles:
        # Match on the last 10 digits / email so formatting differences don't matter.
        for h in name_handles:
            clauses.append("REPLACE(REPLACE(REPLACE(h.id,'+',''),'-',''),' ','') LIKE ?"
                           if "@" not in h else "h.id = ?")
            params.append(f"%{h}%" if "@" not in h else h)
    where = "WHERE (" + " OR ".join(clauses) + ")"
    if args.days:
        cutoff = (datetime.now(timezone.utc).timestamp() - APPLE_EPOCH - args.days * 86400) * 1e9
        where += " AND m.date >= ?"
        params.append(cutoff)
    params.append(args.limit)
    rows = con.execute(
        MSG_SELECT + " " + where + " ORDER BY m.date DESC LIMIT ?", params
    ).fetchall()
    if not rows:
        print(f"No messages matched '{args.who}'.", file=sys.stderr)
        return
    print_messages(reversed(rows), args.json)


def cmd_chats(con, args):
    """List conversations by most recent activity."""
    rows = con.execute(
        """
        SELECT COALESCE(NULLIF(c.display_name,''),
                        GROUP_CONCAT(DISTINCT h.id)) AS name,
               COUNT(DISTINCT m.ROWID) AS n,
               MAX(m.date) AS last_date
        FROM chat c
        JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
        JOIN message m ON m.ROWID = cmj.message_id
        LEFT JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
        LEFT JOIN handle h ON h.ROWID = chj.handle_id
        GROUP BY c.ROWID
        ORDER BY last_date DESC
        LIMIT ?
        """,
        (args.limit,),
    ).fetchall()
    if args.json:
        print(json.dumps([
            {"chat": CONTACTS.pretty_chat(r["name"]), "messages": r["n"],
             "last": to_local(apple_ns_to_dt(r["last_date"])).isoformat()}
            for r in rows], ensure_ascii=False, indent=2))
        return
    for r in rows:
        last = to_local(apple_ns_to_dt(r["last_date"]))
        print(f"{last:%Y-%m-%d}  {r['n']:>6} msgs  {CONTACTS.pretty_chat(r['name'])}")


def cmd_needs_reply(con, args):
    """Chats where the most recent message is inbound (not from me) — i.e. the
    ball is in my court. Automated senders (5-6 digit shortcodes) are excluded
    unless --include-automated is set."""
    cutoff = (datetime.now(timezone.utc).timestamp() - APPLE_EPOCH - args.days * 86400) * 1e9
    rows = con.execute(
        """
        WITH last_per_chat AS (
            SELECT cmj.chat_id AS chat_id, MAX(m.date) AS last_date
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE m.date >= ?
            GROUP BY cmj.chat_id
        )
        SELECT m.date, m.is_from_me, m.text, m.attributedBody,
               m.cache_has_attachments,
               h.id AS handle,
               COALESCE(NULLIF(c.display_name,''),
                        (SELECT GROUP_CONCAT(h2.id) FROM chat_handle_join chj
                         JOIN handle h2 ON h2.ROWID = chj.handle_id
                         WHERE chj.chat_id = c.ROWID)) AS chat_name
        FROM last_per_chat l
        JOIN chat_message_join cmj ON cmj.chat_id = l.chat_id
        JOIN message m ON m.ROWID = cmj.message_id AND m.date = l.last_date
        JOIN chat c ON c.ROWID = l.chat_id
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        WHERE m.is_from_me = 0
        ORDER BY m.date DESC
        """,
        (cutoff,),
    ).fetchall()
    out = []
    for r in rows:
        handle = r["handle"] or ""
        # Shortcodes (all-digit senders) are alerts/marketing, not conversations.
        if not args.include_automated and re.fullmatch(r"\d{3,6}", handle):
            continue
        dt = to_local(apple_ns_to_dt(r["date"]))
        text = body(r) or ("<attachment/no text>" if r["cache_has_attachments"] else "")
        # A thread ending with their tapback reaction isn't awaiting a reply.
        if re.match(r"(Loved|Liked|Laughed at|Emphasized|Disliked|Questioned|Reacted) .{0,12}[“\"]", text):
            continue
        out.append({
            "date": dt.isoformat() if dt else None,
            "chat": CONTACTS.pretty_chat(r["chat_name"] or handle),
            "from": CONTACTS.pretty(handle or "unknown"),
            "last_message": text,
        })
    if args.json:
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return
    if not out:
        print(f"Nothing awaiting a reply in the last {args.days} days.")
        return
    for it in out:
        ts = it["date"][:16].replace("T", " ") if it["date"] else "?"
        who = it["chat"] if it["chat"] != it["from"] else it["from"]
        label = f"{who}" if who == it["from"] else f"{who} (last: {it['from']})"
        print(f"[{ts}] {label}: {it['last_message']}")


def cmd_search(con, args):
    """Search message bodies. Fast path uses the text column; blobs are decoded
    on the fly up to --scan most-recent messages (they lack a searchable index)."""
    q = args.query.lower()
    results = []
    where = ""
    params = []
    if args.days:
        cutoff = (datetime.now(timezone.utc).timestamp() - APPLE_EPOCH - args.days * 86400) * 1e9
        where = "WHERE m.date >= ?"
        params.append(cutoff)
    params.append(args.scan)
    cur = con.execute(
        MSG_SELECT + " " + where + " ORDER BY m.date DESC LIMIT ?", params
    )
    for r in cur:
        text = body(r)
        if text and q in text.lower():
            results.append(r)
            if len(results) >= args.limit:
                break
    if not results:
        print(f"No matches for '{args.query}' in the last {args.scan} messages"
              + (f" within {args.days} days." if args.days else "."), file=sys.stderr)
        return
    print_messages(reversed(results), args.json, show_chat=True)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    # Shared options usable either before or after the subcommand.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="machine-readable output")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("recent", parents=[common], help="latest messages across all chats")
    s.add_argument("--limit", type=int, default=30)
    s.set_defaults(func=cmd_recent)

    s = sub.add_parser("with", parents=[common], help="conversation with a person or chat")
    s.add_argument("who", help="phone / email substring or chat display name")
    s.add_argument("--limit", type=int, default=50)
    s.add_argument("--days", type=int, default=0, help="only the last N days")
    s.set_defaults(func=cmd_with)

    s = sub.add_parser("chats", parents=[common], help="list conversations by recent activity")
    s.add_argument("--limit", type=int, default=25)
    s.set_defaults(func=cmd_chats)

    s = sub.add_parser("needs-reply", parents=[common],
                       help="chats whose last message is inbound (awaiting my reply)")
    s.add_argument("--days", type=int, default=4, help="look-back window (default 4)")
    s.add_argument("--include-automated", action="store_true",
                   help="include shortcode/alert senders")
    s.set_defaults(func=cmd_needs_reply)

    s = sub.add_parser("search", parents=[common], help="search message text")
    s.add_argument("query")
    s.add_argument("--limit", type=int, default=30, help="max matches to return")
    s.add_argument("--scan", type=int, default=50000,
                   help="how many recent messages to scan (blobs have no index)")
    s.add_argument("--days", type=int, default=0, help="restrict scan to last N days")
    s.set_defaults(func=cmd_search)

    args = p.parse_args()
    con = connect()
    con.row_factory = sqlite3.Row
    try:
        args.func(con, args)
    finally:
        con.close()


if __name__ == "__main__":
    main()
