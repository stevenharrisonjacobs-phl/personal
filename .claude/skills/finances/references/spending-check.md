# /finances → Spending check (recent vs benchmark)

A **read-only** pulse check: how the last few weeks of spending compare to the
usual pace, by category, so you can see what's running hot or cold. Lighter than
the full Advisor review — this answers "how am I doing lately," not "how long does
our cash last." Never mutate.

## 1. Pick the window

Default is the **last 6 weeks**. If the user names a window ("past 3 weeks", "this
month"), use it. State the exact date range in the answer.

## 2. Run the benchmark query

`queries/spending-vs-benchmark.sql` compares three windows per category, all
normalized to **$/week** so they're comparable:

- **recent** — the last 6 weeks (the window you're grading).
- **usual** — trailing 12 months excluding the recent window (the benchmark).
- **last year** — the same 6 calendar weeks one year ago (the seasonal cross-check).

```
./scripts/query.sh queries/spending-vs-benchmark.sql
```

To change the window, edit the three `INTERVAL 6 WEEK` literals **and** the two
divisors (`/ 6.0` for the recent/last-year weeks, `/ 46.0` for the baseline =
52 − recent-weeks). Keep them consistent or the per-week rates won't line up.

Excludes business (`COALESCE(institution,'') != 'Mercury'`), internal transfers,
and non-expense flows. If an income or transfer question is really being asked, use
`analyze-data.md` instead.

## 3. Grade each category

Compute `Δ = recent_per_week − usual_per_week` and flag, but **only for material
categories** (usual or recent ≥ ~$25/wk — don't flag noise):

- **HOT** — recent ≥ ~40% over usual. The thing worth looking at.
- **COLD** — recent ≤ ~40% under usual.
- Everything else — on pace.

## 4. The critical read: is a "cold" category real, or a missed obligation?

**A category near zero this window is not automatically good news.** Two very
different causes look identical in the table:

- **Genuine discretionary pullback** — ate out less, no travel. A real win.
- **A bill that didn't get paid** — the failure hides as "savings." Always check
  **Housing** (mortgage — was unpaid since 4 May 2026, see the Advisor review),
  **Taxes** (estimated taxes — $0 reserved), **Insurance**, and any fixed monthly
  vendor showing ~$0 recent. If a fixed obligation is cold, surface it as a **red
  flag**, not a saving.

Then use the **last-year column** for seasonal categories so you don't misread a
calendar effect as a behavior change: Kids Recreation (summer camp), Travel,
Utilities, Restaurants all swing seasonally. If recent ≈ last year but ≠ usual,
that's the season, not you.

## 5. Drill into what's hot

For each HOT category, pull the recent-window vendors so the number has a story.
Write a comment-free `.sql` to `.context/`, e.g.:

```sql
SELECT COALESCE(vendor_name, description) AS vendor,
       ROUND(SUM(-amount),0) AS spend, COUNT(*) AS n, MAX(transaction_date) AS last_seen
FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions`
WHERE flow_type='expense' AND COALESCE(institution,'') != 'Mercury'
  AND COALESCE(canonical_category, category) = 'Transportation'
  AND transaction_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 6 WEEK)
GROUP BY 1 ORDER BY spend DESC;
```

A one-off (a flight, a car repair) reads very differently from a step-change in a
recurring vendor — say which it is.

## 6. Report

Lead with the one-line verdict: **recent pace vs usual pace** in $/week, and whether
the gap is real spending change or deferred obligations. Then the hot/cold table
(recent/wk, usual/wk, Δ, last-year/wk), then a short plain-English list of what
moved and why. Prefer aggregates; don't dump transaction IDs.

Disclose: the **window dates**, and that transfers, refunds, income, and business
spend are excluded.

## 7. Optional — transaction-level review

For a line-by-line keep/cut/ask pass over the window (the mid-session "six-week
review" from the original workup), the Advisor review's interactive dashboard has a
**Review** tab that tags transactions and saves to localStorage. See
`references/cash-flow-review.md` §7. Offer it only if the user wants to go
transaction-by-transaction.
