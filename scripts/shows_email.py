#!/usr/bin/env python3
"""Email newly-announced Philly shows by Steven's Spotify artists.

Runs the /shows match, keeps a seen-cache so it only reports what's NEW since
last time, and emails the fresh matches. Intended for a weekly cron/launchd job.

Deliberately does NOT use the repo's Gmail OAuth (which is send-disabled by
design). Sends via a dedicated Gmail App Password over SMTP — a single-purpose
credential that only ever emails Steven.

.env config:
  SHOWS_SMTP_USER          gmail address that sends (e.g. you@gmail.com)
  SHOWS_SMTP_APP_PASSWORD  16-char Google App Password (myaccount.google.com/apppasswords)
  SHOWS_EMAIL_TO           recipient (optional; defaults to SHOWS_SMTP_USER)

Usage:
  scripts/shows_email.py            email only NEW matches (silent if none)
  scripts/shows_email.py --all      email the full current list (ignore seen-cache)
  scripts/shows_email.py --dry-run  print the email to stdout, don't send
"""
import datetime as dt
import os
import smtplib
import ssl
import sys
from email.message import EmailMessage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shows  # noqa: E402  (reuse the whole matching pipeline)


def _cfg():
    shows.spotify._load_env()
    user = os.environ.get("SHOWS_SMTP_USER")
    pw = os.environ.get("SHOWS_SMTP_APP_PASSWORD")
    to = os.environ.get("SHOWS_EMAIL_TO", user)
    if not user or not pw:
        sys.exit("Missing SHOWS_SMTP_USER / SHOWS_SMTP_APP_PASSWORD in .env "
                 "(create a Gmail App Password at myaccount.google.com/apppasswords).")
    return user, pw, to


def _render(matches):
    today = dt.date.today().strftime("%b %-d, %Y")
    subject = f"🎟 {len(matches)} new Philly show{'s' if len(matches) != 1 else ''} from your Spotify artists"

    lines = [f"New matches as of {today}:\n"]
    rows = []
    for m in matches:
        date = m["date"] or "date TBA"
        bill = f'  (on bill: "{m["billing"]}")' if shows.norm(m["billing"]) != shows.norm(m["artist"]) else ""
        lines.append(f"• {date}  —  {m['artist']}\n    {m['venue']}, {m['city']}  [{m['source']}]{bill}\n    {m['url']}")
        rows.append(
            f'<tr><td style="padding:6px 12px 6px 0;white-space:nowrap;color:#555">{date}</td>'
            f'<td style="padding:6px 0"><b>{m["artist"]}</b><br>'
            f'<span style="color:#666">{m["venue"]}, {m["city"]}</span> '
            f'&nbsp;<a href="{m["url"]}">tickets</a></td></tr>'
        )
    text = "\n".join(lines)
    html = (
        f'<div style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;font-size:15px">'
        f'<h2 style="margin:0 0 4px">🎟 {len(matches)} new show{"s" if len(matches)!=1 else ""} '
        f'from your Spotify artists</h2>'
        f'<div style="color:#888;margin-bottom:12px">Philadelphia area · {today}</div>'
        f'<table style="border-collapse:collapse">{"".join(rows)}</table>'
        f'<p style="color:#aaa;font-size:12px;margin-top:20px">via /shows — Ticketmaster + venue feeds</p></div>'
    )
    return subject, text, html


def _send(user, pw, to, subject, text, html):
    msg = EmailMessage()
    msg["From"] = user
    msg["To"] = to
    msg["Subject"] = subject
    msg.set_content(text)
    msg.add_alternative(html, subtype="html")
    with smtplib.SMTP_SSL("smtp.gmail.com", 465, context=ssl.create_default_context()) as s:
        s.login(user, pw)
        s.send_message(msg)


def main():
    args = sys.argv[1:]
    dry = "--dry-run" in args
    all_matches = "--all" in args

    taste = shows.taste_graph()
    events = shows.gather(radius=40, horizon=365)
    matches = shows.match(events, taste, horizon=365)

    if not all_matches:
        seen = shows.load_seen()
        fresh = [m for m in matches if shows._event_id(m) not in seen]
        if not dry:  # dry-run must not advance the seen-cache
            shows.save_seen(seen | {shows._event_id(m) for m in matches})
        matches = fresh

    if not matches:
        print("No new matches — nothing to email.")
        return

    subject, text, html = _render(matches)
    if dry:
        print(f"--- DRY RUN ---\nSubject: {subject}\n\n{text}")
        return
    user, pw, to = _cfg()
    _send(user, pw, to, subject, text, html)
    print(f"✓ Emailed {len(matches)} match{'es' if len(matches)!=1 else ''} to {to}.")


if __name__ == "__main__":
    main()
