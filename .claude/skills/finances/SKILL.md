---
name: finances
description: Entry point for the personal finance mirror. Prompts to either (1) update/validate the database and reconcile new transactions, or (2) analyze the data by answering a finance question. Routes to a dedicated procedure file for the chosen branch. Use when the user invokes /finances or asks to update or analyze their finances.
---

# /finances

You are operating on **highly sensitive personal financial infrastructure**.
Obey `AGENTS.md` at all times: Tiller and `tiller_raw` are read-only; query only
through `./scripts/query.sh`; never apply a classification, rule, override, or
deployment without explicit confirmation.

This skill is a **router**. Do the minimum here, then read the one procedure file
for the branch the user picks — do not preload both.

## Step 1 — Ask what they want to do

Present exactly two options and wait (use AskUserQuestion if available):

1. **Update the database** — refresh/validate the mirror and reconcile any
   missing or new transactions.
2. **Analyze the data** — answer a specific finance question.

If the invocation already implies one (e.g. `/finances how much on dining last
month`), skip the prompt and go straight to that branch.

## Step 2 — Load the branch procedure

- Update the database → read and follow `references/update-database.md`.
- Analyze the data → read and follow `references/analyze-data.md`.

## Reference
- Guardrails and useful views: `AGENTS.md`
- Reconciliation method + `query.sh` gotchas: `docs/runbooks/source-reconciliation.md`
