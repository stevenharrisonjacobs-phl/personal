---
name: finances
description: Entry point for the personal finance mirror. Routes to one of four branches — (1) update/validate the database and reconcile new transactions, (2) analyze the data by answering a specific finance question, (3) run a full advisor review (cash flow, burn rate, monthly nut, runway & stress tests), or (4) a spending check comparing the last few weeks against the usual benchmark. Use when the user invokes /finances or asks to update or analyze their finances, asks about cash flow / burn rate / runway / whether they can afford something, or asks how their recent spending compares to normal.
---

# /finances

This is a personal finance mirror. See `AGENTS.md` for data notes. Tiller and
`tiller_raw` are the upstream source; everything downstream is derived and
rebuildable, so apply fixes/deploys directly when warranted. Just don't commit
secrets or row-level data to git (keep it in `.context/`).

This skill is a **router**. Do the minimum here, then read the one procedure file
for the branch the user picks — do not preload both.

## Step 1 — Ask what they want to do

Present exactly four options and wait (use AskUserQuestion if available):

1. **Update the database** — refresh/validate the mirror and reconcile any
   missing or new transactions.
2. **Analyze the data** — answer a specific finance question.
3. **Advisor review** — a full household cash-flow / burn-rate / runway workup:
   the monthly nut, real-cash vs amortized views, stress tests. For directional
   decisions ("can we afford X", "how long does our cash last").
4. **Spending check** — how the last few weeks compare to the usual benchmark,
   by category. A quick pulse, not the full review.

If the invocation already implies one, skip the prompt and go straight to that
branch — e.g. `/finances how much on dining last month` → Analyze; `/finances
what's our burn` or `can we afford $10k to paint the house` → Advisor review;
`/finances how's my spending lately` or `am I over budget the past few weeks` →
Spending check.

## Step 2 — Load the branch procedure

- Update the database → read and follow `references/update-database.md`.
- Analyze the data → read and follow `references/analyze-data.md`.
- Advisor review → read and follow `references/cash-flow-review.md`.
- Spending check → read and follow `references/spending-check.md`.

## Reference
- Guardrails and useful views: `AGENTS.md`
- Reconciliation method + `query.sh` gotchas: `docs/runbooks/source-reconciliation.md`
