---
name: finances
description: Entry point for the personal finance mirror. Routes to one of three branches — (1) update/validate the database and reconcile new transactions, (2) analyze the data by answering a finance question, (3) advisor review of cash flow, burn rate, the monthly nut and runway. Works in Claude Code against the repo and in Cowork through the personal-door connector. Use when the user invokes /finances or asks to update, analyze, or review their finances.
---

# /finances

Personal finance mirror over Tiller → BigQuery. Load the shared `personal` skill
first — it carries the transport rule (door vs local scripts), the tool catalog,
and the write discipline. See `AGENTS.md` for mirror guardrails.

This skill is a **router**. Do the minimum here, then read the one procedure file
for the branch the user picks — do not preload more than one.

## Step 1 — Ask what they want to do

Present exactly three options and wait (use AskUserQuestion if available):

1. **Update the database** — refresh/validate the mirror and reconcile any
   missing or new transactions.
2. **Analyze the data** — answer a specific finance question.
3. **Advisor review** — cash flow, burn rate, the monthly nut, runway.

If the invocation already implies one (e.g. `/finances how much on dining last
month`), skip the prompt and go straight to that branch.

## Step 2 — Load the branch procedure

- Update the database → `references/update-database.md`
- Analyze the data → `references/analyze-data.md`
- Advisor review → `references/cash-flow-review.md`

## Step 0, always — is the data even current?

Before any answer, check feed freshness — `feed_health()` through the door, or
`queries/source-freshness.sql` locally. A silently dead bank feed makes a
confident answer quietly wrong; that is exactly how three mortgage payments went
unnoticed for a quarter. Judge accounts against each other, never against an
absolute threshold.

## Reference

- Transport, catalog, guardrails: the shared `personal` skill
- Semantics and join traps: `context/definitions.md`
- Mirror guardrails and useful views: `AGENTS.md`
- Reconciliation method + `query.sh` gotchas: `docs/runbooks/source-reconciliation.md`
