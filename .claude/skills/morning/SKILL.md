---
name: morning
description: Chief-of-staff morning briefing in three sections — Weather, Meetings/Events (work + personal + family), and a Comms breakdown of who's awaiting a reply. Use when the user invokes /morning or asks for a daily briefing, "what's on my plate", or "catch me up".
---

# /morning

Produce a **chief-of-staff briefing** for a busy exec with two young kids. The
reader has 3 minutes. Surface what matters, kill the noise, and make every item
actionable. The brief has exactly three sections: **Weather**, **Meetings /
Events**, and **Comms breakdown**. All access is local/read-only — you can never
send, confirm, cancel, or reply to anything; you can only create Gmail drafts if
explicitly asked.

## Step 0 — Context

Read `docs/people-and-workstreams.md` first: who people are, which meetings
matter, household services, VIPs, and topics to exclude. Weigh every judgment
call in Step 2 against it. Steven is in the **Philadelphia** area.

## Step 1 — Gather (run these in parallel via Bash)

```bash
date "+%A %Y-%m-%d %H:%M"                                              # anchor "today"
curl -s "wttr.in/Philadelphia?format=j1"                              # weather (no key)
scripts/gcal.py agenda --days 7 --json --limit 120                    # week of events, all accounts
scripts/imessages.py needs-reply --days 4 --json                      # texts awaiting my reply
scripts/gmail.py needs-reply --days 7 --json --limit 30               # email threads awaiting my reply
scripts/slack.py needs-reply --days 7 --json                          # Slack DMs, local workspaces (Plum Growth)
grep -rl "" projects/**/*.md 2>/dev/null                              # project tracker files
```

Also read the project tracker (`projects/work/*.md`, `projects/personal/*.md`):
each file's NEXT ACTION, open loops, and `last_touched:` frontmatter. This is the
passive-grooming pass — surface anything stale (>14d) or cold (>30d).

Notes:
- **Weather** — parse today from `weather[0]` (maxtempF/mintempF, hourly
  `chanceofrain`) and `current_condition[0]` (temp_F, FeelsLikeF, weatherDesc).
  Scan `weather[1..]` for anything notable the rest of the week (a rain day, a
  heat spike, a sharp cold drop). If `wttr.in` errors or is empty, say "weather
  unavailable" in that section — never invent a forecast.
- **Bobsled Slack** comes from the claude.ai connector, not the local script. If
  the `mcp__claude_ai_Slack__*` tools are connected, optionally pull DMs sent to
  me (see `/comms` Step 1 for the exact query) and fold into the Work bucket
  tagged `slack:bobsled`. If the connector is offline this session, skip it
  silently — `/comms` is the deep-dive path.
- Warnings on stderr like `skipping <account>` mean a stale token; keep going and
  add a one-line footer telling the user to run `scripts/google_auth.py add`.
- If a section errors entirely, say so in that section — never fabricate.

## Step 2 — Synthesize

Apply judgment; do not dump raw data:

- **Weather → what to do**: translate the forecast into a decision, not just
  numbers. Rain during the 5pm kid pickup, a heat day for Bruce at camp (sunscreen
  / extra water), a cold morning — say the actionable thing, briefly.
- **Meetings**: merge all calendars. Tag each item `[work]` `[personal]` `[kids]`
  `[family]`. Dedupe the same event on multiple accounts. Call out overlaps,
  double-bookings, and back-to-back stretches. Kids/family logistics are
  first-class — flag anything needing childcare, a gift, an RSVP, or one parent
  covering while the other is out (e.g. the daily 5pm Kid Pickup vs. a late
  meeting).
- **Comms noise**: drop newsletters, promos, security alerts, "welcome" mail,
  receipts, cold outreach (incl. sales dressed as `Re:` replies), fantasy sports,
  sale blasts. A message from a *person* to *him* outranks everything.
- **Texts**: `needs-reply` is pre-filtered but still includes group banter —
  include a group thread only if it has a direct question or a logistics
  commitment (reservations, dates, someone coming to the house). Keep genuinely
  actionable automated texts (doctor confirmations, contractors); drop shortcodes
  and marketing.
- **Ages**: for anything awaiting a reply, say how old it is ("3d").

## Step 3 — Format

```
# Morning brief — {Weekday, Mon D}

## Weather
One or two lines: today's conditions, high/low, feels-like, rain chance — then
the *so-what* (umbrella for pickup, sunscreen for camp, layers). Add a single
heads-up line only if the rest of the week has something worth pre-empting.

## Meetings / Events
**Today** — chronological, merged across all calendars, each tagged
[work] [personal] [kids] [family]. Note conflicts/gaps and the 5pm pickup
inline. Lead with anything hard-deadline or unmissable.
**Rest of the week** — a light day-by-day look-ahead (Tue 7/14 …); only the
items worth knowing now (travel, RSVPs, a parent out, big meetings).

## Comms breakdown
Who's waiting on a reply from me, split by area, priority order. Keep it to the
highlights — this is the lighter cousin of /comms.
**Work** — [channel] **Name** · {age} — what they need. _Suggested: one line._
**Personal** — [channel] **Name** · {age} — what they need. _Suggested: …_
Close with: "Full triage → /comms. Want me to draft any of these?" (Gmail
drafts only — never send; no send path for texts or Slack.)

Then, only if the grooming pass found anything, one short trailer: projects whose
NEXT ACTION is unset, or whose loops/`last_touched` have gone stale (>14d 🟡) or
cold (>30d 🔴) — name the project and its next action, then nudge "want to
`/groom` these?" Skip entirely when every project is healthy.
```

Keep the whole brief under ~55 lines. Bold names, keep timestamps short
(Tue 9:00), never print message IDs or account tokens unless asked.
