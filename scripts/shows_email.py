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

Sends a weekly digest: newly-announced matches highlighted in a section up top,
followed by everything else still upcoming that you've already seen.

Usage:
  scripts/shows_email.py            email the digest (new on top, then seen)
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


def _text_row(m):
    date = m["date"] or "date TBA"
    bill = f'  (on bill: "{m["billing"]}")' if shows.norm(m["billing"]) != shows.norm(m["artist"]) else ""
    return f"• {date}  —  {m['artist']}\n    {m['venue']}, {m['city']}  [{m['source']}]{bill}\n    {m['url']}"


def _html_row(m):
    date = m["date"] or "date TBA"
    return (
        f'<tr><td style="padding:6px 12px 6px 0;white-space:nowrap;color:#555">{date}</td>'
        f'<td style="padding:6px 0"><b>{m["artist"]}</b><br>'
        f'<span style="color:#666">{m["venue"]}, {m["city"]}</span> '
        f'&nbsp;<a href="{m["url"]}">tickets</a></td></tr>'
    )


def _render(new, seen_before):
    today = dt.date.today().strftime("%b %-d, %Y")
    n = len(new)
    if n:
        subject = f"🎟 {n} new + {len(seen_before)} upcoming Philly show{'s' if len(seen_before) != 1 else ''}"
    else:
        subject = f"🎟 Your {len(seen_before)} upcoming Philly shows (nothing new)"

    # plain text
    parts = []
    if new:
        parts.append("🆕 NEW THIS WEEK\n" + "\n".join(_text_row(m) for m in new))
    if seen_before:
        header = "📅 STILL UPCOMING (already on your radar)" if new else "📅 UPCOMING (nothing new this week)"
        parts.append(header + "\n" + "\n".join(_text_row(m) for m in seen_before))
    text = f"Philadelphia-area shows by your Spotify artists · {today}\n\n" + "\n\n".join(parts)

    # html
    sections = ""
    if new:
        sections += (
            '<h3 style="margin:18px 0 4px;color:#c026d3">🆕 New this week</h3>'
            f'<table style="border-collapse:collapse">{"".join(_html_row(m) for m in new)}</table>'
        )
    if seen_before:
        h = "Still upcoming" if new else "Upcoming (nothing new this week)"
        sections += (
            f'<h3 style="margin:22px 0 4px;color:#555">📅 {h}</h3>'
            f'<table style="border-collapse:collapse">{"".join(_html_row(m) for m in seen_before)}</table>'
        )
    html = (
        '<div style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;font-size:15px">'
        '<h2 style="margin:0 0 2px">🎟 Your Philly shows</h2>'
        f'<div style="color:#888;margin-bottom:4px">from your Spotify artists · {today}</div>'
        f'{sections}'
        '<p style="color:#aaa;font-size:12px;margin-top:22px">via /shows — Ticketmaster + venue feeds</p></div>'
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

    taste = shows.taste_graph()
    events = shows.gather(radius=40, horizon=365)
    matches = shows.match(events, taste, horizon=365)

    if not matches:
        print("No upcoming matches at all — nothing to email.")
        return

    seen = shows.load_seen()
    new = [m for m in matches if shows._event_id(m) not in seen]
    seen_before = [m for m in matches if shows._event_id(m) in seen]
    if not dry:  # advance the seen-cache so next week's "new" is accurate
        shows.save_seen({shows._event_id(m) for m in matches})

    subject, text, html = _render(new, seen_before)
    if dry:
        print(f"--- DRY RUN ---\nSubject: {subject}\n\n{text}")
        return
    user, pw, to = _cfg()
    _send(user, pw, to, subject, text, html)
    print(f"✓ Emailed digest to {to}: {len(new)} new, {len(seen_before)} previously seen.")


if __name__ == "__main__":
    main()
