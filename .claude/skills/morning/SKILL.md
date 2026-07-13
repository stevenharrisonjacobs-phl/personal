---
name: morning
description: Chief-of-staff morning briefing — the week ahead across all calendars (work + personal + family), emails and texts awaiting a reply, and open loops. Use when the user invokes /morning or asks for a daily/weekly briefing, "what's on my plate", or "catch me up".
---

# /morning

Produce a **chief-of-staff briefing** for a busy exec with two young kids. The
reader has 3 minutes. Surface what matters, kill the noise, and make every item
actionable. All access is local/read-only — you can never send, confirm, cancel,
or reply to anything; you can only create Gmail drafts if explicitly asked.

## Step 0 — Context

Read `docs/people-and-workstreams.md` first: who people are, which meetings
matter, household services, VIPs, and topics to exclude. Weigh every judgment
call in Step 2 against it.

## Step 1 — Gather (run these in parallel via Bash)

```bash
date "+%A %Y-%m-%d %H:%M"                                              # anchor "today"
scripts/gcal.py agenda --days 7 --json --limit 120                     # week of events, all accounts
scripts/gmail.py search "category:primary is:unread" --days 7 --json --limit 30
scripts/gmail.py search "is:starred" --days 45 --json --limit 15       # open loops
scripts/imessages.py needs-reply --days 4 --json
```

Notes:
- Warnings on stderr like `skipping <account>` mean a stale token; keep going
  and add a one-line footer telling the user to run `scripts/google_auth.py add`.
- If a section errors entirely, say so in that section — never fabricate.

## Step 2 — Synthesize

Apply judgment; do not dump raw data:

- **Noise**: drop newsletters, promos, security alerts, "welcome" mail, fantasy
  sports, sale blasts. A message from a *person* to *him* outranks everything.
- **Texts**: `needs-reply` output is pre-filtered but still includes group-chat
  banter — include a group thread only if it contains a direct question or a
  logistics commitment (reservations, dates, someone coming to the house).
  Automated texts from full-length numbers (medical confirmations, contractors)
  are often genuinely actionable — keep those.
- **Kids & family logistics**: events on family/school calendars (ClassDojo,
  Family, spouse's calendars) are first-class. Flag anything needing childcare,
  a gift, an RSVP, or one parent covering while the other is out.
- **Conflicts**: call out overlapping events, double-bookings, and days that are
  back-to-back. Dedupe the same event appearing on multiple accounts' calendars.
- **Ages**: for anything awaiting a reply, say how old it is ("3 days").

## Step 3 — Format

```
# Morning brief — {Weekday, Mon D}

## Top of mind
3-5 bullets max. The things he'd be upset to discover he missed: hard
deadlines, today's appointments, unanswered direct questions, conflicts.

## Needs a response
**Texts** — who, what, how old, suggested one-line action.
**Email** — [account] who, subject, how old, suggested action.

## The week
Day-by-day (Mon 7/13 …), merged across all calendars. Tag each item
[work] [personal] [kids] [family]. Note gaps/conflicts inline.

## Open loops
Starred mail, unfinished threads, anything aging past a week.

## Suggested actions
Numbered, concrete, ≤5 ("1. Text 1 to Penn Medicine to confirm Tue 9am").
Offer: "want me to draft any of these replies?" (drafts only — never send).
```

Keep the whole brief under ~60 lines. Bold names, keep timestamps short
(Tue 9:00), never print message IDs or account tokens unless asked.
