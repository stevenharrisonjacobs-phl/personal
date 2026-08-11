# ARCHIVE — Off-mirror manual account balances (Hannah Trust / Oasic) — 2026-08-11

> **Audience:** the next human or Claude agent who opens this branch cold.
> Read this top-to-bottom; it is the canonical record of what this workspace did.
> Everything below reflects the state at archive time.

- **Workspace:** louisville (Conductor worktree — now archived/deleted)
- **Branch:** `finance-manual-balances` → open PR against `main` (cherry-picked from the diverged local `main`)
- **Status at archive:** DONE — deployed to BigQuery and verified live; git change up for review.

## What this did & why

Added a durable way to include **off-Tiller accounts that have no bank feed** in
the finance mirror and net worth. Steven gained access to an investment account —
**Hannah Trust at Oasic (…3595), $445,415.33** — that Tiller can't import. It's
wired in the **same way as the off-mirror income precedent** (PR #7,
`finance.manual_income`, the Kinship/KTRADE 401k): the dollar figure lives **only
in BigQuery**, never in git. This is the balance-side sibling of that pattern.

## Key changes

- **`finance.manual_balances`** (new BigQuery table, `steven-tiller-finance-2026.finance`)
  — holds hand-entered balances. Schema mirrors `manual_income`: `balance_id,
  owner, account_name, account_number_masked, institution, account_type,
  account_class, balance, as_of_statement, notes`. **Amounts exist only here, not
  in git.** First row: `hannah-trust-oasic`.
- **`sql/refresh.sql`** — new `manual_balance_rows` CTE reads `finance.manual_balances`
  and `UNION ALL`s it into `balance_history`, re-stamped to `CURRENT_DATE()` each
  refresh so the balance always counts in `v_current_balances`, the current month's
  `v_monthly_net_worth`, and `gold.accounts`. Statement date preserved in
  `source_payload` for provenance. (Contains references only — no amounts.)
- **`queries/manual-balances.sql`** (new) — lists the table for transparency; no amounts.

## Current state

- **Deployed and live.** `./scripts/deploy.sh` ran successfully (after Drive re-auth),
  which rebuilt `balance_history` AND updated the "Tiller hourly mirror" scheduled
  query, so the manual union persists on every hourly refresh.
- **Verified:** Hannah Trust appears in `v_current_balances` (Investment/asset,
  $445,415.33, current-dated) and `gold.accounts` (balance-only account:
  has_balance_history=true, has_transactions=false). **Net worth Aug 2026 =
  $978,312.69** (assets $990,126.49 − liabilities $11,813.80), $445K included.
- Commit `954a7cb` verified to contain **no dollar amount** in the diff.

## Next steps / open loops

- [ ] Merge the PR (git side only — the BigQuery side is already live and independent of the merge).
- [ ] **To update the balance from a fresh statement** (no code change, no redeploy):
      `UPDATE finance.manual_balances SET balance=…, as_of_statement=… WHERE balance_id='hannah-trust-oasic';`
- [ ] **To add another off-Tiller account:** `INSERT` a row into `finance.manual_balances`,
      then one `./scripts/deploy.sh` (needs `gcloud auth login steven@plumgrowth.ai --enable-gdrive-access --force`).
- Note: local `main` in this worktree was stale — 3 merged PRs behind origin (#1, #3, #7)
  and 7 unpushed commits. This work was isolated onto its own branch rather than pushing
  the diverged `main`; the other 6 local commits (shows/weather/archive-skill) were left as-is.

## How to resume

```bash
git fetch origin
git checkout finance-manual-balances    # or the PR branch
# read this file, then:
./scripts/query.sh queries/manual-balances.sql     # see the manual accounts (no amounts in git)
```

Transaction-review context from this session: feeds are healthy; the only stale
accounts (Citi AAdvantage …5823 and …2173) are stale because they were **canceled
for fraud** — expected, not a broken feed. `.context/` scratch (statement PDF/PNG,
401k notes, analysis SQL) is preserved in the archive dir alongside transcripts.

<!-- The /archive skill appends the "## Session transcripts" manifest below. -->

## Session transcripts

Archived to `/Users/stevenjacobs/Library/Mobile Documents/com~apple~CloudDocs/conductor-archives/louisville-2026-08-11/transcripts/` on 2026-08-11 (branch at capture: `main`).
Original live path: `/Users/stevenjacobs/.claude/projects/-Users-stevenjacobs-conductor-workspaces-personal-louisville`
(may be reused by a future workspace of the same name).

| Session ID | Msgs | Size | First activity | Last activity |
|---|---|---|---|---|
| `8b92f818-a61c-491b-a3da-5d27bb386328` | 217 | 816K | 2026-08-11T18:15:03.795Z | 2026-08-11T19:44:14.923Z |
| `efff6907-4f73-4e8b-a8b5-5eb640807e25` | 312 | 3.3M | 2026-08-11T16:39:11.234Z | 2026-08-11T18:15:33.783Z |

Also preserved: `.context/` scratch and attachments at
`/Users/stevenjacobs/Library/Mobile Documents/com~apple~CloudDocs/conductor-archives/louisville-2026-08-11/context/`.
