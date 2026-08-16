---
doc: verified-queries
owner: Steven
last-reviewed: 2026-08-16
update-when: a novel query proves itself against the warehouse (add it); a view
  changes shape and a query here breaks (fix or remove it — a stale query here
  is worse than no query)
---

# Verified queries — question → proven SQL

**Adapt one of these before writing novel SQL.** They encode the sign
conventions and exclusions that make an answer correct.

The repo's `queries/*.sql` are the canonical, tested set and are runnable by name
through the door — call `list_saved_queries()` / `saved_query(name)` rather than
retyping them. This doc covers the shapes that are *not* already a file, plus the
adaptations that come up most.

> Placeholders: files in `queries/` use `__PROJECT_ID__`, `__FINANCE_DATASET__`,
> `__GOLD_DATASET__`. The door substitutes these automatically, exactly as
> `scripts/lib.sh` does for `query.sh`, so the same SQL runs identically either
> way. When writing novel SQL through `run_finance_query`, use the real names
> (`gold.transactions`, `finance.v_spending`).

## Already a saved query — call it by name

| Question | Name |
|---|---|
| Is a feed broken? | `source-freshness` (or the `feed_health()` tool) |
| Spending by month and category | `monthly-spending` |
| Biggest vendors | `top-vendors` |
| What's uncategorized? | `uncategorized` |
| Current balances / account rollup | `current-balances`, `account-summary` |
| Category typology and mappings | `categories`, `category-mappings` |
| Trips and projects | `epics`, `epic-transactions` |
| Flow breakdown / unresolved flows | `flow-summary`, `flow-review` |
| Off-mirror income lines | `manual-income` |
| Vendor identity review | `vendor-aliases`, `vendor-canonical-map`, `vendor-review-queue` |
| Anomalies awaiting review | `anomaly-review` |

## Adaptations that come up constantly

**Spending by category for a date range.** Use `canonical_category`, not
`category` — see `definitions.md`. Proven against July 2026:

```sql
SELECT parent_category, canonical_category,
       ROUND(SUM(spend_amount), 2) AS spending,
       COUNT(*) AS transactions
FROM gold.transactions
WHERE transaction_date BETWEEN '2026-07-01' AND '2026-07-31'
  AND flow_type = 'expense'
GROUP BY parent_category, canonical_category
ORDER BY spending DESC
```

Returns, for dining: Restaurants & Bars $2,100.68 / 45, Groceries $1,662.13 /
35, Delivery $584.09 / 11, Coffee $229.27 / 16 — all under parent Food & Drink.
The raw-`category` version of this query disagrees; that is the bug, not a
rounding difference.

**Spending for one vendor over time** — go through `gold.transactions` so vendor
identity is the resolved one, not the raw description:

```sql
SELECT DATE_TRUNC(transaction_date, MONTH) AS month,
       ROUND(SUM(spend_amount), 2) AS spending,
       COUNT(*) AS transactions
FROM gold.transactions
WHERE vendor_name = 'Amazon'
  AND flow_type = 'expense'
  AND transaction_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 12 MONTH)
GROUP BY month
ORDER BY month
```

**Income for a range — remember it is incomplete on its own.** This returns only
income that crossed a bank feed; the answer must then add
`finance.v_manual_income` prorated to the range (see `definitions.md`):

```sql
SELECT flow_type, ROUND(SUM(ABS(amount)), 2) AS total, COUNT(*) AS transactions
FROM gold.transactions
WHERE flow_type IN ('earned_income', 'investment_income')
  AND transaction_date BETWEEN '2026-01-01' AND '2026-12-31'
GROUP BY flow_type
```

**The silent-vendor check** — vendors that billed in ≥6 of the last 12 months and
have since gone quiet. This is the shape that would have caught the mortgage:

```sql
WITH monthly AS (
  SELECT vendor_name,
         DATE_TRUNC(transaction_date, MONTH) AS month,
         ROUND(AVG(ABS(amount)), 2) AS avg_amount
  FROM gold.transactions
  WHERE flow_type = 'expense'
    AND transaction_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 12 MONTH)
  GROUP BY vendor_name, month
)
SELECT vendor_name,
       COUNT(*) AS months_billed,
       ROUND(AVG(avg_amount), 2) AS typical_amount,
       MAX(month) AS last_month_billed,
       DATE_DIFF(CURRENT_DATE(), MAX(month), DAY) AS days_since
FROM monthly
GROUP BY vendor_name
HAVING months_billed >= 6 AND days_since > 45
ORDER BY typical_amount DESC
```

## The NULL trap, in query form

Excluding an institution must survive NULLs, or rows disappear silently:

```sql
-- WRONG: drops every NULL-institution row with no error
WHERE institution != 'Mercury'

-- RIGHT
WHERE COALESCE(institution, '') != 'Mercury'
```

## Adding to this doc

A query earns a place here once it has been **run against the warehouse and its
output sanity-checked** — not when it looks right. Record the question it answers
in the user's words, not the table names. A query here that no longer runs is
worse than no query, because it is trusted; delete it rather than leaving it.
