---
doc: accounts
owner: Steven
last-reviewed: 2026-08-16
update-when: an account is connected to or disconnected from Tiller; an
  off-mirror account is added to manual_balances; an account changes from
  actively-fed to dormant
---

# Accounts — what "stale" means here

There are **two** different failures, and the obvious check only sees one.

## Check the mirror before checking the accounts

If the hourly job dies, **every account freezes together** — so comparing
accounts to each other looks perfectly normal while the whole dataset is
frozen. `feed_health()` now returns a `mirror` block; read it first. When
`mirror_suspect` is true, nothing else in the output means anything.

This is not hypothetical. From **2026-08-12 to 2026-08-17** the scheduled query
failed every single hour on one bad cell in the Tiller sheet, and the mirror sat
five days stale. The per-account view looked unremarkable the whole time, and an
agent reading it called the mirror healthy. Absence of new data is not visible
as an anomaly in data — the same blind spot that let three mortgage payments go
unnoticed.

When `mirror_suspect` is true, look at the **"Tiller hourly mirror" scheduled
query** for failures. Fixing it is a source-side or deploy action, and until it
is fixed every answer is missing everything since the newest date shown.

## Then: one account vs the others

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

## Accounts Steven has already ruled on — do NOT re-flag

A dead card and a broken feed look identical from here: both are just an account
that stopped posting. So every run rediscovered these and asked again. Steven has
been asked more than once; stop asking.

| Account | Mask | State |
|---|---|---|
| Citi AAdvantage | 2173 | **Closed.** Not a broken feed. Its last 47 txns (Jun 26 – Jul 8 2026) are real and complete. |
| Citi AAdvantage | 5823 | **Closed.** Same story. |
| Justworks Retirement Savings Plan for Bobsled | 7301 | **Old 401(k).** No longer contributed to, so no new transactions is correct. |

`queries/source-freshness.sql` labels these in a `known_state` column, so the
suppression is in the data rather than resting on whoever reads this file.

**The PNC mortgage autopay is armed** (confirmed 2026-08-18). The Jun–Jul gap and
the $9,520.59 catch-up on Aug 12 are settled history, already amortized across
Jun–Aug. Do not raise it as an open question again.

When a genuinely new account goes quiet, say so. When one of these does, say
nothing.

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
