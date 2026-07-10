# Financial management agent

This repository contains highly sensitive personal financial infrastructure.

## Guardrails

- Treat Tiller and `tiller_raw` as read-only sources of truth.
- Query only through `./scripts/query.sh` unless the user explicitly asks for a
  deployment or classification change.
- Prefer aggregates. Do not print full account IDs, transaction IDs, account
  numbers, or raw descriptions unless the user explicitly needs row-level data.
- The DB can be incomplete when a bank feed silently stops importing. Check with
  `queries/source-freshness.sql` and reconcile against a Copilot export per
  `docs/runbooks/source-reconciliation.md` (match on amount + date + account
  name, never the card mask). Keep row-level reconciliation output in `.context/`.
- Always state the date range and whether transfers, refunds, income, and
  uncategorized transactions were included.
- Tiller expenses are negative. Use `finance.v_spending.spend_amount` when
  reporting positive spending.
- Do not treat transfers or credit-card payments as spending. The standard
  queries exclude categories containing `transfer`, but verify unusual cases.
- Never invent a category. When uncertain, show a short merchant summary and
  ask before adding a rule or override.
- Add reusable merchant logic with `scripts/add-rule.sh`; use
  `scripts/add-override.sh` only for a single transaction.
- Never commit `.env`, exported transactions, query results, OAuth tokens, or
  service-account keys.

## Useful views

- `gold.transactions`: the default transaction model. It is deduplicated and
  includes vendor, category, canonical flow type, confidence/evidence,
  cash-flow, and calendar fields.
- `gold.transaction_flow_review`: transactions whose flow cannot be safely
  resolved from source evidence. Never silently coerce these into income or
  transfers.
- `gold.transaction_anomaly_review_queue`: session-reviewed anomalies and source
  ambiguities. Treat suggestions as review material only; never apply them
  automatically.
- `gold.vendors`: one row per inferred vendor with category and spend metrics.
- `gold.accounts`: one row per account with latest balance and activity metrics.
- `gold.categories`: durable category typology derived from Copilot and mapped
  across source systems.
- `gold.category_aliases`: source-to-canonical category mappings for Tiller and
  Copilot.
- `gold.epics`: one row per trip, project, or celebration. Large purchases stay
  in the category model and are not epics.
- `gold.epic_transactions`: Copilot epic assignments with conservative links
  to matching Tiller transactions. Unlinked rows remain part of epic totals.
- `finance.v_transactions_classified`: all normalized transactions plus final
  classification and its source.
- `finance.v_spending`: outflows with positive `spend_amount`.
- `finance.v_current_balances`: latest balance per account.
- `finance.v_monthly_net_worth`: month-end net worth history.

Prefer the `gold` models for analysis. Add exact vendor-name mappings with
`scripts/add-vendor-alias.sh`, regex mappings with `scripts/add-vendor-rule.sh`,
and one-off corrections with `scripts/add-vendor-override.sh`.
