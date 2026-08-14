---
name: weather
description: Delta-first weather — not the raw numbers, but whether it's getting better or worse than it said before. Day-over-day (vs yesterday) plus forecast revisions (how the forecast for an upcoming day has drifted across snapshots). Use when Steven invokes /weather or asks "what's the weather", "is it worse than yesterday", "did the weekend forecast change", "should I worry about Saturday".
---

# /weather

Steven checks weather for **deltas, not raw numbers** — "is this worse than
yesterday?" and "is the forecast getting worse than it said before?" The raw
temperature is secondary. Lead with the change.

## Step 1 — Get a fresh, current briefing

```bash
scripts/weather.py brief --refresh
```

`--refresh` takes a new snapshot first (so "today" is live) and then diffs it
against the stored history. Add `--days N` for a longer outlook, `--location <key>`
or `--lat/--lon` for elsewhere (`scripts/weather.py locations` lists known ones).

The tool already does the synthesis — print its output more or less verbatim.
It has three parts:
- **TODAY vs YESTERDAY** — the day-over-day verdict (↑ better / ↓ worse) + drivers.
- **FORECAST REVISIONS** — how upcoming days have drifted since earlier snapshots.
  A "trending WORSE — N snapshots running" line is the high-value signal: the
  models keep downgrading that day. If it says "need ≥2 to diff," the history is
  still building — say so plainly, don't fabricate a revision.
- **OUTLOOK** — the compact next-N-days strip.

## Step 2 — Add judgment on top (optional)

Only if it earns the words:
- If a **weekend or a specific plan** is trending worse across snapshots, call it
  out directly ("Saturday's been downgraded 3 snapshots running — if the outdoor
  plan is flexible, Sunday now looks better").
- To show the full revision trail for one day: `scripts/weather.py history YYYY-MM-DD`.
- Never invent numbers the tool didn't return. If a section is empty, say why.

## Notes

- Requires network (Open-Meteo). If the snapshot fails, run `scripts/weather.py brief`
  without `--refresh` to show the last stored snapshot, and note it may be stale.
- The revision signal only works because a cron job snapshots the forecast twice
  daily. The longer it's been running, the richer the revisions. It cannot be
  backfilled — a missed day is a permanent gap.
