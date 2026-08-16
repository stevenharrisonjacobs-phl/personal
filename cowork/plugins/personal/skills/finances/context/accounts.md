---
doc: accounts
owner: Steven
last-reviewed: 2026-08-16
update-when: an account is connected to or disconnected from Tiller; an
  off-mirror account is added to manual_balances; an account changes from
  actively-fed to dormant
---

# Accounts — what "stale" means here

`feed_health()` reports days since each account's latest transaction. That number
is meaningless on its own. **Judge accounts against each other, never against an
absolute threshold**, and use this doc to tell a broken feed from a quiet one.

## The rule

> An account with **many transactions in the last 30 days** but a
> `days_since_latest` far above the other active cards has a **broken feed**.
> An account with few transactions and a high `days_since_latest` is simply
> quiet, and is not a problem.

Trusts, retirement, and investment accounts are naturally quiet. Do not raise
them. Checking accounts and active credit cards are not — a week of silence on
one of those is worth a sentence.

The fix for a broken feed is **reconnecting that account in Tiller**. It is a
source-side action: nothing in the repo changes, and the mirror backfills on its
own afterward. Say that rather than proposing a code change.

## Accounts with no bank feed at all

Some accounts are invisible to the mirror by nature and are tracked by hand:

- **`finance.manual_balances`** — balances for off-feed accounts. First row:
  Hannah Trust / Oasic.
- **`finance.manual_income`** — income arriving off-feed (Hannah's Kinship
  401(k) via KTRADE: employee deferral + employer match, tracked from the
  quarterly PDFs).

These never appear in `feed_health` because they have no transactions to be
stale. Their staleness is **how recently a human updated them**, which no query
can see. When an answer depends on one, say when it was last refreshed.

## Known blind spots

- **The mortgage funding account (PNC) is not linked to Tiller.** Roughly $38k a
  year of outflow is therefore invisible to the mirror, and every forecast has to
  assume it rather than observe it. This is the gap that let three mortgage
  payments go unnoticed. Until PNC is connected, say so in any cash-flow answer.
- **Balance history begins 2026-04-07.** Jumps around that date are accounts
  being connected, not wealth changing. Never read them as growth.
- **Home value and mortgage balance are not tracked**, so net worth excludes
  both — it is a liquid-and-investable figure, not a true net worth.

## The check no freshness query performs

A feed can be perfectly healthy while a recurring obligation simply **stops**.
Absence raises no alert. See `references/update-database.md` §3a for the
silent-vendor check; run it as part of any update or advisor review.
