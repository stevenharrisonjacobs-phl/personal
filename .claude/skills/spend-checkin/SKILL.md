---
name: spend-checkin
description: Daily spend check-in — "what have I spent since my last check-in?" Reads the latest 6am report (personal transactions + watch items, Snapfix consumption with week-over-week trends, Mercury subscriptions) through the personal door, or generates a fresh one in Claude Code. Use when the user says "morning check-in", "spend check-in", "/spend-checkin", or asks what they've spent since last checking.
---

# /spend-checkin

Load the shared `personal` skill first — it carries the transport rule (door
vs local fallback), the door catalog, and the write discipline.

Two branches. **Consume is the default**; generate only when explicitly asked
(or when invoked with the `generate` argument by the 6am runner).

## Consume — show the latest report (any surface)

1. Fetch the newest successful report:
   - **Door transport (Cowork / claude.ai):** `saved_query("latest-spend-checkin")`.
   - **Local fallback (Claude Code):** run the same query locally via
     `./scripts/query.sh` against `finance.checkin_reports` (newest
     `status='success'` row).
2. **Staleness check before rendering:** if the row's `run_ts` predates the
   most recent 6:00 AM America/New_York boundary, render the report WITH a
   warning line ("this report predates this morning's 6am run — the Mac may
   not have run yet"). The warning accompanies the report, never replaces it.
3. Render `report_md` as-is. The window header and Notes are part of the
   report — do not strip them.
4. Door errors come back as `{status, error}` — quote them verbatim, never
   retry a refusal, never route around the door.
5. Follow-ups ("show me all dining this month", "what's that charge") go
   through the door's governed query surface per the shared `personal` skill.
   Classification changes are decided anywhere but applied in Claude Code
   only — relay what should change and stop.

## Generate — build this morning's report (Claude Code only)

Read `references/generate.md` and follow it. Generation runs locally in
Claude Code (the 6am launchd runner, or Steve ad hoc). It writes exactly one
row via `scripts/checkin-write.sh` — never direct DML.

**An ad-hoc generation run advances the checkpoint** (check-in = successful
generation run): the next morning's report covers the shorter window since
this run. Consuming never advances anything.

**Headless rule:** the generation branch is selected by invocation argument
and never asks an interactive question — a headless session deadlocks on one.

## Context

- `context/mercury-mapping.md` — Mercury counterparty → venture tags
- `context/expected-recurrings.md` — curated watch-item expectations
- Sign conventions and join traps: the finances skill's `context/definitions.md`
