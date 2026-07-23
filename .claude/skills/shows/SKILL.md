---
name: shows
description: Finds when Steven's Spotify artists are playing the Philadelphia area — pulls his listening history and matches it to upcoming concerts (Ticketmaster + indie venue scrapers). Use when Steven invokes /shows, or asks "who's coming to Philly", "any of my bands playing", "concerts near me", "should I get tickets to anything".
---

# /shows

Surface upcoming **Philadelphia-area concerts by artists Steven actually listens
to on Spotify**. The whole pipeline is one script; your job is to run it and
present the results well.

## Run it

```bash
python3 scripts/shows.py            # all upcoming matches, date-sorted
python3 scripts/shows.py --new      # only shows not seen on a prior run (for weekly check-ins)
python3 scripts/shows.py --json     # structured, if you need to reshape output
```

Optional flags: `--radius <miles>` (default 40, covers Camden/Ardmore/Glenside),
`--horizon <days>` (default 365).

## Weekly email digest (automated)

`scripts/shows_email.py` emails a weekly digest to Steven — **new** shows in a
section up top, everything else still-upcoming below — via a dedicated Gmail App
Password (SMTP), NOT the repo's send-disabled Gmail OAuth. It runs from the
canonical repo (`~/conductor/repos/personal`) via a launchd job, Mondays 08:07.

- Manage: `launchctl print gui/$(id -u)/com.stevenjacobs.philly-shows`
- Run now: `launchctl kickstart -k gui/$(id -u)/com.stevenjacobs.philly-shows`
- Logs: `.context/shows-email.log` / `.err.log` in the canonical repo
- Reinstall: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.stevenjacobs.philly-shows.plist`
  (template committed at `scripts/com.stevenjacobs.philly-shows.plist`)
- Needs `SHOWS_SMTP_*` in `.env` + the same `.env`/`.secrets` present at whatever
  path launchd runs from.

## How it works (so you can explain / debug)

1. **Taste graph** — `scripts/spotify.py` pulls ~100 artists via the Spotify Web
   API: top artists across 3 time ranges + followed artists. Matching is on
   artist **name** (Spotify no longer returns genres).
2. **Concert sources**:
   - **Ticketmaster Discovery API** — all Music events within `radius` of
     Philadelphia; exact structured artist match.
   - **Venue JSON-LD scrapers** (tixr) — Underground Arts, Ardmore Music Hall,
     MilkBoy. Dates are UTC in the markup; converted to Eastern (`_local_date`).
   - **rhp_events RSS venues** — Johnny Brenda's, R5 Productions (First Unitarian
     / PhilaMOCA / Ukie Club), Kung Fu Necktie. The `/events/feed/` RSS gives the
     full roster (the HTML page only shows ~25); the show date isn't in the feed,
     so it's fetched per-match from the event page's `article:expiration_time`.
   - **World Cafe Live** — via its JamBase venue pages (own site is
     TLS-fingerprint-blocked to non-browsers). JamBase throttles, so `_fetch`
     retries on 429; a failed pull just drops WCL for that run.
3. Matches are deduped by (artist, date, venue) and date-sorted. Free-text venue
   bills are matched by whole-title / per-act / word-boundary passes, so a
   support-slot artist still surfaces (the `on bill:` line shows the full bill).

## Present the results

- Lead with a one-line count and the **soonest** show.
- Group or highlight by time (this month vs later) if the list is long.
- Always keep the **date, venue, and ticket link** — those are the action.
- If a match came from a venue scraper (not Ticketmaster), that's expected extra
  coverage; no need to caveat it.
- Offer to save tickets/interest to the project tracker via `/park` if Steven
  reacts to a specific show.

## Failure modes

- `Not authorized` from Spotify → run `scripts/spotify.py auth` (opens browser).
- A single venue failing prints a `!` warning to stderr but the run continues —
  report partial results, don't abort.
- Empty result is legitimate (nobody touring Philly right now) — say so plainly.

## Coverage gaps (known)

Verified against Ticketmaster's actual venue return: nearly every mid/large room
IS on Ticketmaster — incl. Union Transfer (71 events), Brooklyn Bowl, and Xfinity
Mobile Arena (renamed Wells Fargo Center) — so those need no scraper.

World Cafe Live is now covered via JamBase (its own site is TLS-fingerprint-
blocked; TM barely carries it). Remaining gaps are small DIY rooms, all low
relevance: City Winery, The Fire, Ortlieb's, Silk City, Connie's Ric Rac —
various platforms, some Dice.

To add a venue, extend `VENUE_SCRAPERS` in `scripts/shows.py` (JSON-LD or rhp RSS
if the site supports it). See [[philly-shows-agent]] memory for dead ends.
