# /finances → Analyze the data

Answer a specific finance question with **read-only** queries. Never mutate.

## 1. Pin down the question

Get (or infer, then state) the question and the **date range**. Clarify only if
genuinely ambiguous — otherwise pick a sensible range and say what you used.

## 2. Check for an existing query first

`queries/` already has: `monthly-spending.sql`, `top-vendors.sql`,
`uncategorized.sql`, `current-balances.sql`, `account-summary.sql`,
`categories.sql`, `epics.sql`, `epic-transactions.sql`, `flow-summary.sql`,
`flow-review.sql`, `vendor-*`, `source-freshness.sql`, `manual-income.sql`
(off-mirror PDF-tracked income). Reuse one if it fits.

## 3. Write and run the query

- Prefer the `gold` models (`gold.transactions`, `gold.vendors`, `gold.epics`,
  etc.). Use `finance.v_spending.spend_amount` for **positive** spending (Tiller
  expenses are negative).
- Write a **comment-free** `.sql` file to `.context/` — a leading `--` comment
  breaks `query.sh` (it strips to the next `;`). Then:
  ```
  ./scripts/query.sh .context/<name>.sql
  ```
- Output over a few KB is saved to a file; read that file, not the truncated
  preview. The wrapper caps at 200 rows — aggregate or narrow if you hit it.

## 3a. Include off-mirror manual income

Some income is tracked by hand from statements/PDFs, not through a bank feed, and
lives in `finance.manual_income` (surfaced by `finance.v_manual_income`, listed by
`queries/manual-income.sql`). **Any income answer must add these lines** — they are
real income in a different bucket, not double-counted spending. Prorate by the
answer's date range: `monthly_amount × months_in_range`. Current lines: Hannah's
Kinship 401(k) via KTRADE (employee deferral + employer match), tracked from the
quarterly PDFs in `.context/`. Caveat: Hannah's Kinship paycheck already appears in
the mirror as earned income (vendor `Newco Public Relations`), but that is her
**take-home, already net of the 401(k) deferral** — so the `employee_deferral` line is
additive, not a double-count. It would only double-count if a *gross*-pay figure were
ever added. The `employer_match` line never touches the accounts and is always net-new.

## 4. Exclude non-spending correctly

Do not count transfers or credit-card payments as spending. The standard queries
exclude categories containing `transfer`; verify unusual cases. Use `flow_type`
(`expense`, `refund_reimbursement`, `internal_transfer`, `credit_card_payment`,
…) when direction matters.

## 5. Report with the required disclosures

Always state:
- the **date range**, and
- whether **transfers, refunds, income, and uncategorized** transactions were
  included or excluded.

Prefer aggregates. Do not print full account IDs, transaction IDs, or account
numbers unless the user explicitly needs row-level detail. A clean table beats a
chart unless a chart genuinely helps (then use the `dataviz` skill).

## 6. Never invent a category

If classification is uncertain, show a short merchant summary and ask before
proposing a rule or override — do not guess.
