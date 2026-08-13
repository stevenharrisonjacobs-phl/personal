---
name: amortize
description: Spread a large one-off purchase across the months it actually covers, so the monthly nut reflects real cost rather than payment timing. Sets a start and end date for a transaction or a project (epic). Use when Steven invokes /amortize, or says "spread this over", "amortize the X", "this shouldn't all hit one month", or asks what a capital purchase costs per month.
---

# /amortize

A capital purchase hits the accounts on one day but is *used* over years. Painting
the house is $10k in September and $0 forever after — which is true of the cash and
false of the cost. This sets an explicit start/end span so
`gold.v_spending_amortized` spreads it.

Read-only until the final write. Never mutate anything but
`gold.amortization_schedule`.

## Step 1 — Identify what to amortize

If Steven named it ("the paint job", "that Pottery Barn charge"), find it. If he
just typed `/amortize`, surface candidates: large, one-off, not already scheduled.

```sql
SELECT t.transaction_key, t.transaction_date, ROUND(t.spend_amount,2) AS amount,
       t.vendor_name, t.canonical_category, COALESCE(t.epic_name,'') AS epic
FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions` AS t
LEFT JOIN `__PROJECT_ID__.__GOLD_DATASET__.amortization_schedule` AS s
  ON s.enabled AND (s.transaction_key = t.transaction_key OR s.epic_name = t.epic_name)
WHERE t.flow_type = 'expense' AND t.spend_amount >= 750
  AND COALESCE(t.institution,'') != 'Mercury'
  AND s.amortization_id IS NULL
  AND t.transaction_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 18 MONTH)
ORDER BY t.spend_amount DESC LIMIT 25;
```

Write comment-free SQL to `.context/` and run via `./scripts/query.sh` — a leading
`--` breaks the wrapper.

**Transaction or epic?** If the purchase is one charge, target the transaction. If
it's several (deposit + installments, or a renovation with many vendors), target
the **epic** so they amortize together from one start date — and tag the
transactions to that epic first if they aren't already.

## Step 2 — Propose the span

Ask for start and end, but **propose a default** rather than asking cold. Useful
lives to suggest:

| Purchase | Typical life |
|---|---|
| Interior/exterior paint | 5 years |
| Appliance | 8–10 years |
| Furniture | 7–10 years |
| Roof / HVAC | 15–20 years |
| Car | 5–8 years |
| Computer / phone | 3 years |
| Mattress | 8 years |

Default **start** = the month of the charge, unless the thing gets used later (a
deposit in June for work done in September starts in September).

Confirm the span in plain terms before writing: *"$10,000 from Sep 2026 through
Aug 2031 — 60 months, $167/mo."*

## Step 3 — Write it

```
./scripts/add-amortization.sh txn  <transaction_key> <start> <end> "label"
./scripts/add-amortization.sh epic "<Epic Name>"     <start> <end> "label"
```

Dates are `YYYY-MM-DD`, end is **inclusive**. Re-running for the same target
replaces the schedule, so this is also how you edit or correct one.

## Step 4 — Show the effect

Report the before/after so the change is legible:

- **Cash view** — unchanged; the money still left in the original month.
- **Amortized view** — $X/mo across N months.
- **Effect on the monthly nut** — pull the category's `cost_behavior` tier and show
  the new per-month figure.

```sql
SELECT amortized_month, ROUND(SUM(amortized_amount),2) AS amount, amortization_source
FROM `__PROJECT_ID__.__GOLD_DATASET__.v_spending_amortized`
WHERE transaction_key = '<key>' GROUP BY 1,3 ORDER BY 1;
```

## Guardrails

- **Never amortize consumption.** Groceries, restaurants, travel, subscriptions are
  used when bought. Amortization is for things with a *useful life*. If the ask is
  "smooth out my lumpy restaurant spending," that's a reporting-window question, not
  this.
- **Recurring lumps are scheduled too, one at a time.** There is no automatic
  per-category spreading — an earlier `cadence` column tried that and was the wrong
  grain (a category holds annual dues *and* $4 drop-in charges). So an annual gym
  bill gets its own 12-month schedule each year. It's a handful of charges a year.
- **Tax liability is not amortized — it's accrued.** `finance.accruals` recognises
  it monthly as revenue is earned, which is more accurate than spreading the
  quarterly payment backward. Don't schedule tax payments here.
- **Conservation holds.** `SUM(amortized_amount) == SUM(spend_amount)` over all
  time — amortizing moves cost between months, it never creates or destroys it. If
  a change breaks that equality, something is wrong.
- **Amortized ≠ affordable.** The cash still leaves in month one. When the question
  is "can we afford this," answer from cash and runway; use the amortized view for
  "what does a normal month cost."

## Reference
- Span precedence and view logic: `sql/gold.sql` → `v_spending_amortized`
- Cost tiers: `gold.categories` (`cost_behavior`, `essential`)
- Accruals (pre-amortization): `sql/projections.sql` → `v_accrued_costs`
- Guardrails and views: `AGENTS.md`
