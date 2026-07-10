# /finances → Update the database

The hourly scheduled query already refreshes the mirror automatically, so a manual
"update" is mostly **verification and reconciliation**, not a rebuild. Work through
these in order; stop and report at each step rather than pushing through silently.

## 1. Check feed freshness (always do this first)

```
./scripts/query.sh queries/source-freshness.sql
```

Each row is an account with its latest transaction date and `days_since_latest`.
Compare accounts against each other, not against an absolute threshold:

- An account with many `txns_last_30d` but a `days_since_latest` far higher than
  the other active cards has a **broken/stale feed** (this is the usual cause of
  "we're missing transactions").
- Low-activity accounts (trusts, some investment/retirement accounts) are
  naturally stale — do not raise those as problems.

If a feed is stale, tell the user to **reconnect / re-authorize that account in
Tiller**. The mirror backfills on its own afterward — this is a source-side fix,
nothing in the repo changes.

## 2. Reconcile a Copilot export (if the user has a fresh CSV)

Follow `docs/runbooks/source-reconciliation.md`:

- Parse with a real CSV parser (embedded commas in category names break naive
  splitting).
- Match on **absolute amount + date (±4 days) + normalized `account_name`** —
  never the card mask (masks diverge between the two systems).
- Return only the gaps (embed CSV rows as `UNNEST([STRUCT(...)])` + `NOT EXISTS`).
- Present the missing set grouped and summarized. **Keep row-level output in
  `.context/` — never commit merchants or amounts.**

Remember Copilot expenses are positive (opposite of Tiller); compare `ABS`.

## 3. Review flagged rows

Surface, as review material only (never auto-apply):

- `gold.transaction_flow_review` — flows that can't be safely resolved.
- `gold.transaction_anomaly_review_queue` — session-reviewed anomalies.

## 4. Only mutate with explicit confirmation

Refreshes, deploys, and classification changes touch durable state. Do not run
`deploy.sh`, `validate.sh`, the `*-finance-onboarding.sh` scripts, `add-rule.sh`,
`add-override.sh`, or any vendor/alias script unless the user explicitly asks.
When a fix is warranted, propose the exact command and wait.
