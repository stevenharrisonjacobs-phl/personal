# Runbook: reconciling Tiller (DB) against a Copilot export

This repo's DB (`gold.transactions`, sourced from Tiller bank feeds) is **not always
complete**. Bank connections can silently stop importing. Copilot is a second,
independently-maintained record of the same spending. Neither is complete on its
own, so reconciliation is a union, not a subtraction.

This runbook captures the non-sensitive method. Row-level results (merchants,
amounts) must stay out of git — keep them in the gitignored `.context/` per the
repo guardrails.

## Two sources, and how they differ

| | Tiller → `gold.transactions` (the DB) | Copilot export CSV |
|---|---|---|
| Expense sign | **negative** | **positive** (income negative) |
| Account label | `account_name`, `account_number_masked` | `account`, `account mask` |
| Completeness | misses any card whose feed broke | misses very recent, not-yet-synced charges |

**Match key: absolute amount + date (±4 days) + normalized `account_name`.**
Do **not** match on the card mask — the same physical card can appear under
different last-4 masks in the two systems (e.g. a reissued Citi card shows one
last-4 in Copilot and another in Tiller), so a mask join produces massive false
"missing" counts. Account *names* line up cleanly; masks do not.

## Detecting a broken/stale feed

A feed that stops importing is the most common cause of "we're missing
transactions." Detect it with a per-account freshness check:

```
./scripts/query.sh queries/source-freshness.sql
```

Any account whose `days_since_latest` is much larger than the others has a
stale connection. **Fix at the source** — reconnect / re-authorize that account
in Tiller. The hourly scheduled query then backfills automatically; nothing in
this repo needs to change.

## Diffing a Copilot CSV against the DB (read-only)

The `query.sh` wrapper only allows a single `SELECT`/`WITH` and caps output at
200 rows, and it cannot load a file. To diff an external CSV anyway, embed the
CSV rows into the query as a literal and let BigQuery return only the gaps:

1. Parse the CSV with a real CSV parser (fields like `Recreation, Travel &
   Transit` contain commas — naive comma-splitting corrupts columns).
2. Emit each row as `STRUCT(DATE '..' AS d, NUMERIC '..' AS amt, '..' AS acct, ..)`
   inside `WITH csv AS (SELECT * FROM UNNEST([ ... ]))`.
3. Return only unmatched rows with a correlated `NOT EXISTS` against
   `gold.transactions` using the match key above. Output stays small and the
   query passes the SELECT-only guard.

A generator + the produced SQL live in `.context/` (gitignored) as a template.

## query.sh gotchas (learned the hard way)

- **No leading `--` comments.** The wrapper strips everything from `--` to the
  next `;`, which deletes the whole statement and trips "Only SELECT or WITH
  queries are allowed." Keep query files comment-free.
- **`--max_rows=200` is hard-coded.** Design queries to return only what you need
  (aggregate, or return just the diff), or chunk by date.
- Output larger than a few KB is persisted to a file; read that file rather than
  the truncated inline preview.
