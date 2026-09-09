---
name: spend-checkin
description: Daily spend check-in — "what have I spent since my last check-in?" Reads the latest 6am report (personal transactions + watch items, Snapfix consumption with week-over-week trends, Mercury subscriptions) through the personal door, or generates a fresh one (the scheduled cloud routine, or Claude Code as the laptop fallback). Use when the user says "morning check-in", "spend check-in", "/spend-checkin", or asks what they've spent since last checking.
---

# /spend-checkin

Load the shared `personal` skill first — it carries the transport rule (door
vs local fallback), the door catalog, and the write discipline.

Two branches. **Consume is the default**; generate only when explicitly asked
(or when invoked with the `generate` argument by a scheduled runner).

**Morning habit:** the default entry is opening the scheduled routine's
session — the report is already there, warm for drill-down (see
`references/interactive.md`). Cold session? Run `/spend-checkin` consume. A
failed row routes to the runbook triage (`docs/runbooks/cloud-checkin.md`).

## Consume — show the latest report (any surface)

1. Fetch the newest report state:
   - **Door transport (cloud / Cowork):** `saved_query("latest-spend-checkin")`
     for the newest success; when you need today's failed or absent rows too,
     read the recent `finance.checkin_reports` rows via `run_finance_query`.
   - **Local fallback (Claude Code):** the same queries via
     `./scripts/query.sh`.
2. Say which of the five states this morning is in. **Precedence rule: a
   failed row never masks a later success** — consume always renders the
   latest success; failures are context around it, never a replacement for it.
   - **Fresh success** — newest success at/after this morning's 6:00 AM
     America/New_York boundary: render it; nothing to caveat.
   - **DEGRADED-stamped success** — the stamp is the message: name the failed
     source(s) up front, say their totals are null while everything else
     stands, and surface the escalation line if Notes carries one. Never
     re-render without the stamp.
   - **STALE-stamped success** — say the mirror rebuild was more than 6 hours
     old when the report was built, so personal numbers may lag the latest
     arrivals.
   - **Failed row (no later success)** — quote the failure reason verbatim,
     render the last success with a "predates this morning" warning, and
     route to the runbook triage — the scheduled routine did not land today's
     report.
   - **No row at all today** — neither success nor failure: the scheduled
     routine may not have fired, or the platform dropped the run. Render the
     last success with a "this report predates this morning's scheduled run"
     warning and offer to generate fresh. The warning accompanies the report,
     never replaces it.
3. Render `report_md` as-is. The window header, stamps, and Notes are part of
   the report — do not strip them.
4. Door errors come back as `{status, error}` — quote them verbatim, never
   retry a refusal, never route around the door.
5. Follow-ups ("show me all dining this month", "what's that charge") go
   through the door's governed query surface per the shared `personal` skill.
   Classification changes go through the door's write tools under the
   protocol in `references/interactive.md` — explicit ask, echoed parameters,
   landing proof.

## Generate — build this morning's report

Read `references/generate.md` and follow it. Generation runs on one of two
transports: the scheduled claude.ai/code cloud routine (door reads,
`record_checkin` / `record_checkin_failed` writes), or Claude Code on the
laptop as the burn-in fallback (`./scripts/query.sh` reads,
`scripts/checkin-write.sh` write). Exactly one row lands either way — never
direct DML.

**An ad-hoc generation run advances the checkpoint** (check-in = successful
generation run): the next morning's report covers the shorter window since
this run. Consuming never advances anything.

**Headless rule:** the generation branch is selected by invocation argument
and never asks an interactive question — a headless session deadlocks on one.

## Interactive morning session

`references/interactive.md` — the protocol for the routine's session after
the report renders: the today-success check, drill-downs via door reads, the
write protocol (echo → call → landing proof), append-only undo, the human
window, and narrate-and-relay curation of the committed context files.

## Context

- `context/mercury-mapping.md` — Mercury counterparty → venture tags
- `context/expected-recurrings.md` — curated watch-item expectations
- Sign conventions and join traps: the finances skill's `context/definitions.md`
