# Tiller → BigQuery finance mirror

This repository creates a private Google Cloud project that mirrors a Tiller
Google Sheet into BigQuery and adds a safe classification/query layer for a
financial-management agent.

## Ask finance questions with Codex

The personal `$ask-finances` skill is installed in `~/.codex/skills`. Invoke it
in Codex with questions such as:

```text
$ask-finances How much did I spend on restaurants each month this year?
$ask-finances Compare earned income and expenses for the last six complete months.
$ask-finances What did the Greece trip cost, and which vendors were largest?
$ask-finances Show the transactions whose flow still needs review.
```

The skill queries only through the repository's read-only SQL wrapper and uses
canonical flow types rather than the original Tiller transfer label.

## Onboard new transactions with Codex

Invoke the personal `$onboard-finances` skill in an active Codex session:

```text
$onboard-finances Run the complete finance onboarding pipeline.
```

The skill refreshes and validates the mirror, runs every canonical vendor,
category, epic, account, and flow classification, records transactions that
pass deterministic checks, reviews flagged rows with the current Codex session,
and stores structured findings in `gold.transaction_onboarding_reviews`.
Potential issues appear in `gold.transaction_anomaly_review_queue`; suggestions
are never applied to classifications automatically.

By default it scans an overlapping 14-day arrival window and skips keys already
reviewed under `session-v1`, which catches delayed Tiller imports without paying
session attention to the full history on every run.

This workflow uses the active Codex session and does not require an OpenAI API
key, Cloud Run, or a separate model bill. A skill runs only when invoked; the
hourly BigQuery mirror remains automatic, while session review is intentionally
user-started.

## Architecture

1. `tiller_raw.transactions_external` and
   `tiller_raw.balance_history_external` are live BigQuery external tables over
   the Google Sheet.
2. An hourly scheduled query materializes typed, native BigQuery tables in the
   `finance` dataset. This is faster and more stable than querying Sheets for
   every analysis.
3. `finance.classification_rules` and `finance.transaction_overrides` hold
   durable classifications without editing Tiller data.
4. `finance.v_transactions_classified`, `finance.v_spending`,
   `finance.v_current_balances`, and `finance.v_monthly_net_worth` are the
   agent-facing views.
5. The `gold` dataset provides deduplicated enriched transactions, inferred
   vendors, and discrete accounts for agent and reporting use cases.

The visible Tiller `Balances` tab is a formula-driven report. The raw,
append-only source behind it is the usually hidden `Balance History` tab, so
this mirror uses `Balance History` by default.

## One-time setup

The current machine must be authenticated as the Google user who can create a
project, use a billing account, and read the Tiller sheet. A service-account-only
Cloud CLI login is not enough.

```bash
gcloud auth login --enable-gdrive-access
gcloud auth application-default login
cp .env.example .env
# Open .env in an editor, replace the three example values, and save the file.
# Do not enter those assignments as separate terminal commands.
open -e .env
# Then:
./scripts/bootstrap.sh
```

The scheduled query uses your Google user credentials. The first deployment can
print a BigQuery authorization URL; open it, approve BigQuery and Drive access,
then paste the returned `version_info` into the terminal prompt. After bootstrap:

```bash
./scripts/deploy.sh
./scripts/validate.sh
```

No bank credentials, Google tokens, or transaction data are stored in this
repository. The `.env` file is gitignored.

## Classify spending

Rules are evaluated in ascending priority order. A transaction override wins
over a rule, and a rule wins over the category already present in Tiller.

```bash
./scripts/add-rule.sh \
  coffee-shops 100 '(?i)starbucks|la colombe|coffee' Dining Coffee

./scripts/add-override.sh TRANSACTION_KEY Travel "Work trip"
```

The rule script accepts: `rule_id priority description_regex category
[subcategory]`. Regexes use BigQuery's RE2 syntax.

## Query spending

```bash
./scripts/query.sh queries/monthly-spending.sql
./scripts/query.sh queries/uncategorized.sql
./scripts/query.sh queries/current-balances.sql
./scripts/query.sh queries/top-vendors.sql
./scripts/query.sh queries/account-summary.sql
```

## Gold models

- `gold.transactions` keeps one row per transaction key and adds vendor ID/name,
  canonical `flow_type`, confidence/evidence, cash-flow direction, positive
  spend/income/refund measures, transfer/refund flags, and calendar fields.
- `gold.vendors` keeps one row per inferred vendor with its primary category,
  observed categories, activity dates, transaction counts, and spend metrics.
- `gold.vendor_canonical_review` inventories every observed vendor label, its
  canonical name, mapping method, confidence, and review status.
- `gold.accounts` keeps one row per account across both transaction and balance
  sources, including latest balance and lifetime activity.
- `gold.categories` is the durable two-level category typology derived from the
  Copilot export; `gold.category_aliases` maps both Copilot and Tiller labels
  into it.
- `gold.epics` keeps trips, renovations, celebrations, and other bounded projects
  separate from the category typology. `gold.epic_transactions` preserves each
  Copilot assignment and links it to Tiller only when the date, absolute amount,
  and account suffix produce a unique one-to-one match.

Vendor identity is resolved in this order: transaction override, exact alias
lookup, enabled regex rule, then normalized description. Manage it with:

```bash
./scripts/add-vendor-alias.sh "AMZN Marketplace" "Amazon" "Amazon alias"
./scripts/add-vendor-rule.sh RULE_ID PRIORITY REGEX "Vendor Name" "Optional notes"
./scripts/add-vendor-override.sh TRANSACTION_KEY "Vendor Name" "Optional notes"
./scripts/query.sh queries/vendor-aliases.sql
./scripts/query.sh queries/vendor-canonical-map.sql
./scripts/query.sh queries/vendor-review-queue.sql
./scripts/query.sh queries/categories.sql
./scripts/query.sh queries/category-mappings.sql
./scripts/query.sh queries/epics.sql
./scripts/query.sh queries/epic-transactions.sql
./scripts/query.sh queries/flow-summary.sql
./scripts/query.sh queries/flow-review.sql
```

`flow_type` is independent of spending category and uses: `expense`,
`earned_income`, `investment_income`, `refund_reimbursement`,
`internal_transfer`, `credit_card_payment`, `investment_activity`,
`cash_withdrawal`, `adjustment`, and `needs_review`. Rows that cannot be
settled from Copilot evidence, account pairing, direction, or description are
kept in `gold.transaction_flow_review` rather than guessed.

The initial epic lookup is in `gold.epic_definitions`. Generic excluded buckets
such as transfers, taxes, annual subscriptions, and `Issues` are intentionally
not epics. Add a row to that lookup when a new Copilot project label should be
promoted into an epic.

To run a different read-only query, save it as a `.sql` file and pass that file
to `query.sh`. The wrapper rejects DDL and DML. Tiller expenses are negative;
`finance.v_spending.spend_amount` exposes them as positive amounts.

## Operating notes

- Tiller remains the source of truth. Never update the external or materialized
  transaction tables directly.
- The hourly job replaces only the materialized mirror. Rules and overrides are
  separate tables and are preserved.
- Existing sheet columns can be reordered: the external tables use schema
  autodetection, and the refresh SQL normalizes standard Tiller fields by name.
  Re-run `deploy.sh` after adding new columns so BigQuery refreshes the external
  schema.
- If a header is renamed, the corresponding normalized value becomes null until
  the header is restored.
- BigQuery and scheduled-query usage may incur Google Cloud charges. Set a
  billing budget/alert in the new project after deployment.
