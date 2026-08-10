# ARCHIVE — Copilot failsafe for silently-dropped Tiller transactions — 2026-08-10

> **Audience:** the next human or Claude agent who opens this branch cold.
> Read this top-to-bottom; it is the canonical record of what this workspace did.
> Everything below reflects the state at archive time.

- **Workspace:** madison (Conductor worktree — now archived/deleted)
- **Branch:** `tiller-bigquery-finance-mirror` → open **PR #4**
  (earlier commit `4e4a3b9` from this workspace is already **merged to main**)
- **Also from this workspace:** `comms-slack-reply-triage` → open **PR #5**
  (unrelated `/comms` workstream, split out at archive time so it wasn't lost)
- **Status at archive:** DONE — both changes are deployed and verified live; PRs awaiting review

## What this did & why

A `/finances` database-update run turned into a real bug hunt. The per-account
freshness check looked clean, but reconciling a fresh Copilot CSV export against
the mirror surfaced **48 missing Citi AAdvantage transactions** (a Scotland trip,
2026-06-26 → 07-08, $2,784.40). The Tiller/Plaid feed had gone down *mid-window*
and resumed on 07-09, so "days since latest = 4" read healthy while thirteen days
of transactions were simply absent — a failure mode a freshness check structurally
cannot catch.

The root cause was architectural: Copilot data was already being imported into a
bronze table, but the pipeline used it **only as category/flow evidence**, joined
to existing Tiller rows. Copilot rows with no Tiller match were silently dropped,
so the one source that *had* the missing transactions could never supply them.
This branch makes Copilot a genuine failsafe: net-new Copilot rows are unioned
into `finance.transactions`, bounded by each account's Tiller coverage window.

A later session reviewed follow-on work that landed on `main` (`a74ff46`) and found
it left 48 of these rows orphaned into a phantom duplicate account; that is fixed
here too.

## Key changes

- `sql/refresh.sql` (commit `4e4a3b9`, **already merged to main**) — `finance.transactions`
  becomes a union of Tiller rows plus net-new Copilot rows. A Copilot row is injected
  only when it is `posted` + `regular` + not-excluded, falls **inside that account's
  Tiller coverage window** (per-account MIN/MAX `transaction_date`), and has no Tiller
  match on ±4 days + absolute amount + account name. Rows are sign-flipped to Tiller's
  convention and tagged `source='copilot'`.
  - **The coverage-window guard is load-bearing.** Without it the naive rule injects
    **7,888 rows (~$700K)** of pre-2024 Copilot history that Tiller never covered.
    With it: 85 genuine in-window misses.
  - Self-healing: once Tiller backfills a row, the `NOT EXISTS` drops the Copilot
    copy on the next refresh, so there is no double-count.
- `sql/gold.sql` (commit `356ec06`, **PR #4**) — adds an `account_identity_by_name`
  CTE as a fallback when mask-based account canonicalization misses. Injected rows
  carry no `account_id`; `a74ff46` canonicalized them by card mask, which cannot work
  for Citi because **Copilot reports mask 2173/5823 while Tiller reports 9611**.
  Guarded by the same `id_count = 1` rule so genuinely distinct same-named accounts
  (`INVESTMENT` ×5, `Ultimate Rewards` ×2) are left alone. This is what `AGENTS.md`
  already mandates: match on account name, **never the card mask**.

## Current state

- **Deployed and verified live.** `./scripts/deploy.sh` ran successfully for the
  `refresh.sql` change and also updated the "Tiller hourly mirror" scheduled query,
  so the failsafe runs hourly and is permanent. The `gold.sql` fix was applied as
  views (see "How to resume" — it does not need Drive auth).
- **85 rows recovered**, all classified `flow_type='expense'` and flowing into
  `finance.v_spending` ($8,535.76): Citi 48 / $2,784.40 · Total Checking 28 / $4,366 ·
  Amex Gold 9 / $1,385.36.
- **Reconciliation returns zero gaps** for the 90-day window (re-ran the same
  embedded-CSV diff that originally found the 48).
- **Zero `account_id`-less rows** remain (was 48). Citi resolves to a single account:
  931 txns / $39,214.61 — a merge, not a double-count; totals unchanged.
- Row-level reconciliation output was kept in `.context/` (gitignored) and was
  **never committed**, per the repo's no-PII rule.

## Next steps / open loops

- [ ] **The Copilot bronze table is refreshed manually — this is the weakest link.**
      The failsafe can only recover what is in `tiller_raw.copilot_transactions`, and
      that only updates when someone runs
      `./scripts/import-copilot.sh ~/Downloads/transactions.csv` with a fresh export.
      If a feed breaks and Copilot hasn't been re-imported, the gap goes uncaught.
      Monthly would be plenty. Worth a scheduled reminder.
- [ ] **`plumgrowth`'s Drive scope keeps lapsing**, which blocks `deploy.sh`. It has
      now happened twice. Plain `gcloud auth login` silently reuses the cached
      no-Drive token — `--force` is required (see below). A dedicated service account
      with BigQuery + Drive would remove the interactive dance entirely.
- [ ] **Latent, unfixed:** the Copilot *evidence* join in `gold.sql` (~line 376,
      `copilot_transaction_matches`) still matches on **mask + exact date**. Same
      wrong-by-policy rule this branch fixed elsewhere, so category/flow evidence
      silently fails for the Citi card. Not urgent — it degrades enrichment, not
      completeness.
- [ ] `./scripts/validate.sh` was never run (deploy.sh suggests it).
- [ ] **PR #5** — the `/morning` skill change there is a *merge* of this workspace's
      comms work with the upstream project-tracker grooming pass. The tracker nudge
      became a conditional trailer rather than its own section. Confirm that's intended.

## How to resume

```bash
git checkout tiller-bigquery-finance-mirror     # PR #4  (finance)
git checkout comms-slack-reply-triage           # PR #5  (/comms + Slack)
```

Read `AGENTS.md` first — note governance was **relaxed** in `a74ff46`: no read-only
mandate, no ask-before-mutating, and `query.sh` lost its SELECT-only guard and
200-row cap (now `QUERY_MAX_ROWS`, default 100k) and pipes via stdin, so leading
`--` comments now work. Then `docs/runbooks/source-reconciliation.md` for the
reconciliation method.

**Applying `gold.sql` changes without Drive auth** — only `refresh.sql` reads the
Drive-backed Tiller sheet. `gold.sql` defines views over the already-materialized
`finance.transactions` table, so it deploys fine without Drive scope:

```bash
bash -c 'source scripts/lib.sh; load_env; render_sql sql/gold.sql \
  | bq --project_id="$GCP_PROJECT_ID" --location="$BQ_LOCATION" query --use_legacy_sql=false'
```

(`lib.sh` uses `BASH_SOURCE`, so it must run under bash — not the default zsh.)

**Full `deploy.sh` needs Drive scope**, re-authed with `--force` or it silently
reuses the cached token:

```bash
gcloud auth login steven@plumgrowth.ai --enable-gdrive-access --update-adc --force
gcloud auth describe steven@plumgrowth.ai --format='value(scopes)' | tr ',' '\n' | grep drive
```

Gotchas worth knowing: BigQuery escapes single quotes as `\'`, **not** doubled `''`
(doubled produces a "concatenated string literals" error); `rows` is a reserved
word, alias counts as `n`.

## Session transcripts

Archived to `/Users/stevenjacobs/Library/Mobile Documents/com~apple~CloudDocs/conductor-archives/madison-2026-08-10/transcripts/` on 2026-08-10 (branch at capture: `tiller-bigquery-finance-mirror`).
Original live path: `/Users/stevenjacobs/.claude/projects/-Users-stevenjacobs-conductor-workspaces-personal-madison`
(may be reused by a future workspace of the same name).

| Session ID | Msgs | Size | First activity | Last activity |
|---|---|---|---|---|
| `0e86eeb7-016c-42b1-9a2b-a03cd7a6a904` | 116 | 368K | 2026-07-13T20:05:32.163Z | 2026-07-13T22:45:21.189Z |
| `20b69f06-dc09-49ed-a8d7-d6fd8edd24b3` | 716 | 2.5M | 2026-07-10T22:47:43.307Z | 2026-07-13T15:28:39.461Z |
| `68ac677d-76b7-49da-ab2c-f946852b986f` | 355 | 1.9M | 2026-07-13T16:58:54.133Z | 2026-07-13T18:04:48.738Z |
| `7ac35dc3-1092-4849-b536-96c916298497` | 385 | 1.2M | 2026-07-13T18:05:07.022Z | 2026-07-13T19:10:44.790Z |
| `bd8b6c90-6135-486c-acf5-bef50043f241` | 701 | 2.1M | 2026-07-13T22:45:27.565Z | 2026-08-10T21:37:12.536Z |

_To replay a session for debugging:_ `cat "/Users/stevenjacobs/Library/Mobile Documents/com~apple~CloudDocs/conductor-archives/madison-2026-08-10/transcripts/<session-id>.jsonl" | jq -r 'select(.type=="user" or .type=="assistant")'`
