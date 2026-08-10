#!/usr/bin/env python3
"""Read-only access to Slack across one or more workspaces (connector-free).

Mirrors scripts/gmail.py and scripts/imessages.py: it talks straight to the
Slack Web API with a stored user token per workspace, so /comms and /morning can
see Slack without a Claude connector — and, unlike the connector, it can hold
several workspaces at once (e.g. Bobsled *and* Plum Growth). Each workspace's
token lives in .secrets/slack-<name>.json and is never committed.

    scripts/slack.py list                     # authorized workspaces + identity
    scripts/slack.py needs-reply --days 14    # DMs where they spoke last (my court)
    scripts/slack.py dms --limit 20           # recent direct-message threads
    scripts/slack.py read <channel-id>        # read one conversation
Add --json to any command for machine-readable output.

Set up a workspace once (see `scripts/slack.py add --help` for the token steps):
    scripts/slack.py add --name bobsled --token xoxp-...
Nothing here ever sends, edits, or reacts — it is strictly read-only.
"""
import argparse
import glob
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

SECRETS_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".secrets")
API = "https://slack.com/api/"


class SlackError(Exception):
    pass


def _token_path(name):
    return os.path.join(SECRETS_DIR, f"slack-{name}.json")


def list_workspaces(selector=None):
    """Authorized workspaces, read from .secrets/slack-*.json. Optional selector
    is a substring match on the workspace name (like gmail.py's --account)."""
    out = []
    for path in sorted(glob.glob(os.path.join(SECRETS_DIR, "slack-*.json"))):
        name = os.path.basename(path)[len("slack-"):-len(".json")]
        with open(path) as f:
            data = json.load(f)
        data["name"] = name
        out.append(data)
    if selector:
        out = [w for w in out if selector.lower() in w["name"].lower()]
        if not out:
            sys.exit(f"No workspace matches '{selector}'.")
    if not out:
        sys.exit("No Slack workspaces authorized yet. Run: scripts/slack.py add --help")
    return out


def api(token, method, **params):
    """One Slack Web API call. Read methods only are used here."""
    data = urllib.parse.urlencode(
        {k: v for k, v in params.items() if v is not None}).encode()
    req = urllib.request.Request(
        API + method, data=data,
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=30) as r:
        body = json.load(r)
    if not body.get("ok"):
        raise SlackError(body.get("error", "unknown_error"))
    return body


def _paginate(token, method, key, **params):
    """Yield every item from a cursor-paginated list method."""
    cursor = None
    while True:
        body = api(token, method, cursor=cursor, limit=200, **params)
        for item in body.get(key, []):
            yield item
        cursor = body.get("response_metadata", {}).get("next_cursor")
        if not cursor:
            return


class Names:
    """Lazy, cached user-id -> {name, is_bot} resolver for one workspace."""

    def __init__(self, token):
        self.token = token
        self.cache = {}

    def info(self, uid):
        if not uid:
            return {"name": "unknown", "is_bot": False}
        if uid not in self.cache:
            try:
                u = api(self.token, "users.info", user=uid)["user"]
                name = (u.get("profile", {}).get("display_name")
                        or u.get("real_name") or u.get("name") or uid)
                self.cache[uid] = {"name": name, "is_bot": bool(u.get("is_bot"))}
            except SlackError:
                self.cache[uid] = {"name": uid, "is_bot": False}
        return self.cache[uid]

    def name(self, uid):
        return self.info(uid)["name"]


def clean_text(text, names):
    """Turn Slack markup (<@U123>, <#C1|name>, <url|label>) into readable text."""
    if not text:
        return ""
    text = re.sub(r"<@([A-Z0-9]+)>", lambda m: "@" + names.name(m.group(1)), text)
    text = re.sub(r"<#[A-Z0-9]+\|([^>]+)>", r"#\1", text)
    text = re.sub(r"<(https?://[^|>]+)\|([^>]+)>", r"\2", text)
    text = re.sub(r"<(https?://[^>]+)>", r"\1", text)
    text = text.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
    return re.sub(r"\s+", " ", text).strip()


def _ts_to_local(ts):
    return datetime.fromtimestamp(float(ts), tz=timezone.utc).astimezone()


def _dm_label(ws, chan, names):
    """Human label for a DM/group-DM channel."""
    if chan.get("is_im"):
        return names.name(chan.get("user"))
    # mpim: resolve members (Slack gives an auto name like mpdm-a--b--c).
    try:
        members = api(ws["token"], "conversations.members",
                      channel=chan["id"]).get("members", [])
    except SlackError:
        return chan.get("name", chan["id"])
    others = [names.name(m) for m in members if m != ws.get("user_id")]
    return ", ".join(others) if others else chan.get("name", chan["id"])


def _last_message(ws, chan):
    # Slack lists stale/closed IMs that 404 on history; one bad channel must not
    # kill the whole run, so treat any per-channel error as "no message".
    try:
        body = api(ws["token"], "conversations.history", channel=chan["id"], limit=1)
    except SlackError:
        return None
    msgs = body.get("messages", [])
    return msgs[0] if msgs else None


def cmd_add(args):
    """Store a user token for one workspace after verifying it with auth.test."""
    token = args.token or os.environ.get("SLACK_TOKEN")
    if not token:
        sys.exit("Provide a token with --token xoxp-... (or env SLACK_TOKEN).\n"
                 "See `scripts/slack.py add --help` for how to create one.")
    ident = api(token, "auth.test")
    name = args.name or re.sub(r"[^a-z0-9]+", "-",
                               ident.get("team", "workspace").lower()).strip("-")
    os.makedirs(SECRETS_DIR, exist_ok=True)
    record = {"token": token, "team": ident.get("team"),
              "team_id": ident.get("team_id"), "user": ident.get("user"),
              "user_id": ident.get("user_id"), "url": ident.get("url")}
    with open(_token_path(name), "w") as f:
        json.dump(record, f, indent=2)
    os.chmod(_token_path(name), 0o600)
    print(f"✓ Authorized '{name}' — {ident.get('team')} as {ident.get('user')}.")
    print(f"  Saved to .secrets/slack-{name}.json (gitignored).")


def cmd_list(args):
    rows = []
    for ws in list_workspaces(args.workspace):
        try:
            ident = api(ws["token"], "auth.test")
            rows.append({"name": ws["name"], "team": ident.get("team"),
                         "user": ident.get("user"), "ok": True})
        except (SlackError, urllib.error.URLError) as e:
            rows.append({"name": ws["name"], "team": ws.get("team"),
                         "error": str(e), "ok": False})
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return
    for r in rows:
        if r["ok"]:
            print(f"  {r['name']:<12} {r['team']} — as {r['user']}")
        else:
            print(f"  {r['name']:<12} ERROR: {r['error']} "
                  f"(re-add: scripts/slack.py add --name {r['name']} --token ...)")


def cmd_dms(args):
    """Most recent direct-message threads across workspaces."""
    items = []
    multi = len(list_workspaces(args.workspace)) > 1
    for ws in list_workspaces(args.workspace):
        names = Names(ws["token"])
        for chan in _paginate(ws["token"], "conversations.list", "channels",
                              types="im,mpim", exclude_archived="true"):
            last = _last_message(ws, chan)
            if not last:
                continue
            items.append({
                "workspace": ws["name"],
                "channel": chan["id"],
                "with": _dm_label(ws, chan, names),
                "ts": float(last["ts"]),
                "date": _ts_to_local(last["ts"]).strftime("%Y-%m-%d %H:%M"),
                "from": "Me" if last.get("user") == ws.get("user_id")
                        else names.name(last.get("user")),
                "text": clean_text(last.get("text", ""), names),
            })
    items.sort(key=lambda x: x["ts"], reverse=True)
    items = items[:args.limit]
    if args.json:
        print(json.dumps(items, ensure_ascii=False, indent=2))
        return
    for it in items:
        ws = f"[{it['workspace']}] " if multi else ""
        print(f"{it['date']}  {ws}{it['with']}")
        print(f"    {it['from']}: {it['text'][:160]}")


def cmd_needs_reply(args):
    """DM / group-DM threads whose last message is NOT from me — the ball is in
    my court. Bots/apps (Slackbot, workflow apps) are skipped unless
    --include-automated."""
    cutoff = datetime.now(timezone.utc).timestamp() - args.days * 86400
    items = []
    multi = len(list_workspaces(args.workspace)) > 1
    for ws in list_workspaces(args.workspace):
        names = Names(ws["token"])
        for chan in _paginate(ws["token"], "conversations.list", "channels",
                              types="im,mpim", exclude_archived="true"):
            last = _last_message(ws, chan)
            if not last or float(last["ts"]) < cutoff:
                continue
            sender = last.get("user")
            # I spoke last, or it's a non-human event (join/bot) → not my court.
            if sender == ws.get("user_id"):
                continue
            if not sender or last.get("subtype") or last.get("bot_id"):
                if not args.include_automated:
                    continue
            if chan.get("is_im"):
                if sender == "USLACKBOT" and not args.include_automated:
                    continue
                if names.info(sender)["is_bot"] and not args.include_automated:
                    continue
            dt = _ts_to_local(last["ts"])
            items.append({
                "workspace": ws["name"],
                "channel": chan["id"],
                "with": _dm_label(ws, chan, names),
                "ts": float(last["ts"]),
                "date": dt.strftime("%Y-%m-%d %H:%M"),
                "age_days": int((datetime.now(timezone.utc).timestamp()
                                 - float(last["ts"])) // 86400),
                "from": names.name(sender),
                "last_message": clean_text(last.get("text", ""), names),
            })
    items.sort(key=lambda x: x["ts"], reverse=True)
    if args.json:
        print(json.dumps(items, ensure_ascii=False, indent=2))
        return
    if not items:
        print(f"Nothing awaiting your reply in Slack in the last {args.days} days.")
        return
    for it in items:
        ws = f"[{it['workspace']}] " if multi else ""
        who = it["with"] if it["with"] == it["from"] else f"{it['with']} ({it['from']})"
        print(f"[{it['date']}] {ws}{who}: {it['last_message']}")


def cmd_read(args):
    """Print the recent history of one conversation (channel/DM id)."""
    for ws in list_workspaces(args.workspace):
        names = Names(ws["token"])
        try:
            body = api(ws["token"], "conversations.history",
                       channel=args.channel, limit=args.limit)
        except SlackError:
            continue
        msgs = list(reversed(body.get("messages", [])))
        out = [{"date": _ts_to_local(m["ts"]).strftime("%Y-%m-%d %H:%M"),
                "from": "Me" if m.get("user") == ws.get("user_id")
                        else names.name(m.get("user")),
                "text": clean_text(m.get("text", ""), names)} for m in msgs]
        if args.json:
            print(json.dumps(out, ensure_ascii=False, indent=2))
        else:
            for m in out:
                print(f"[{m['date']}] {m['from']}: {m['text']}")
        return
    sys.exit(f"Channel {args.channel} not found in any authorized workspace.")


ADD_HELP = """Create a Slack user token, then store it here.

1. Go to https://api.slack.com/apps -> "Create New App" -> "From scratch".
   Name it e.g. "personal-access"; pick the workspace (do this once per
   workspace: once for Bobsled, once for Plum Growth).
2. Left sidebar -> "OAuth & Permissions". Under "User Token Scopes" add:
     users:read  im:read  im:history  mpim:read  mpim:history
   (add channels:read + channels:history too if you later want channel reads).
3. Top of that page -> "Install to Workspace" -> Allow. Copy the
   "User OAuth Token" (starts with xoxp-).
4. Run:  scripts/slack.py add --name bobsled --token xoxp-...
   Repeat with --name plumgrowth for the second workspace.
The token is stored in .secrets/ (gitignored) and used read-only."""


def main():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--workspace", help="substring of a workspace name; default all")
    common.add_argument("--json", action="store_true")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("add", formatter_class=argparse.RawDescriptionHelpFormatter,
                       help="store a workspace user token", description=ADD_HELP)
    s.add_argument("--name", help="short workspace label (e.g. bobsled); default from team")
    s.add_argument("--token", help="xoxp- user token (or set env SLACK_TOKEN)")
    s.set_defaults(func=cmd_add)

    sub.add_parser("list", parents=[common], help="authorized workspaces").set_defaults(func=cmd_list)

    s = sub.add_parser("dms", parents=[common], help="recent direct-message threads")
    s.add_argument("--limit", type=int, default=20)
    s.set_defaults(func=cmd_dms)

    s = sub.add_parser("needs-reply", parents=[common],
                       help="DMs whose last message is inbound (awaiting my reply)")
    s.add_argument("--days", type=int, default=14, help="look-back window (default 14)")
    s.add_argument("--include-automated", action="store_true",
                   help="include Slackbot/app/bot DMs")
    s.set_defaults(func=cmd_needs_reply)

    s = sub.add_parser("read", parents=[common], help="history of one conversation")
    s.add_argument("channel", help="channel/DM id (e.g. from `dms`)")
    s.add_argument("--limit", type=int, default=30)
    s.set_defaults(func=cmd_read)

    args = p.parse_args()
    try:
        args.func(args)
    except SlackError as e:
        sys.exit(f"Slack API error: {e}")


if __name__ == "__main__":
    main()
