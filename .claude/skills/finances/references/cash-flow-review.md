# /finances → Advisor review

Cash flow, burn rate, the monthly nut, runway. Read-only. This is the branch for
"can we afford X", "how long do we have", "what does a month actually cost".

Method reconstructed from the 2026-08-10/11 household workup, archived at
`~/Library/Mobile Documents/com~apple~CloudDocs/conductor-archives/seattle-2026-08-11/ARCHIVE.md`.
Read `context/household.md` for framing and `context/definitions.md` before any
metric claim.

## 1. The unit of analysis is household + business together

Steven left a W-2 role in March 2026 and runs a consultancy alongside half-time
Bobsled work. Business revenue and household spending land in overlapping
accounts, so a household-only view understates income and a business-only view
understates obligations. **Model them as one unit**, then say which side a number
came from.

## 2. Income, with a tax haircut

Never report self-employment income gross as if it were spendable.

- Pull earned income and business revenue over the range.
- Apply a **35–40% reserve** to self-employment income before calling anything
  available. State the rate you used.
- **Add off-mirror income** from `finance.v_manual_income`, prorated
  (`monthly_amount × months_in_range`). It is additive, not a double-count — see
  `context/definitions.md` for exactly why.
- For each income source, report **months paid out of months in range**. That
  column is the reliability test; a source paying 4 of 12 months is not a salary.

## 3. The monthly nut, in three tiers

Do not produce one blended "monthly spending" number. It hides the thing the
question is really about — which costs are escapable.

| Tier | What goes in it | Where it comes from |
|---|---|---|
| **Fixed** | housing, insurance, utilities, debt service — same every month | recurring vendors, actual amounts |
| **Committed, amortized** | annual and lumpy commitments spread over their term | `gold.v_spending_amortized` / `gold.amortization_schedule` |
| **Seasonal** | the irregular real spending a year actually contains | prior-year actuals for the same months |

Report the three separately, then the total. **Never mix amortized and real-cash
figures inside one total** — that double-counts a commitment in the month it is
actually paid.

## 4. Two views of the year, both stated

- **Real cash** — what actually left the accounts. Answers "did we make it".
- **Amortized** — lumpy commitments spread out. Answers "what does a normal month
  cost".

They disagree, and the disagreement is informative. Show both; never silently
pick one.

## 5. Stress test, then runway

Take liquid + investable assets, subtract the reserved tax liability, divide by
the stressed monthly nut. Then move the levers that actually move — income,
tax reserve, childcare, discretionary trim — and report runway under each.

Give a range, not a single number, and name the assumption that moves it most.

## 6. Say what the data cannot see

Every advisor answer carries its blind spots. Known ones, which persist until
someone fixes the source:

- **Home value and mortgage balance are not tracked**, so net worth excludes both.
- **Balance history starts 2026-04-07.** Jumps near that date are accounts being
  connected, not wealth appearing. Do not read them as growth.
- **Accounts with no bank feed** are only present via `finance.manual_balances`
  and `finance.manual_income` — check `context/accounts.md` for which.
- Any unidentified large deposits — whether they recur materially changes a
  forecast, so surface them rather than absorbing them into a trend.

## 7. Gotchas that have produced wrong numbers here before

- **`institution != 'Mercury'` silently drops NULL-institution rows.** Use
  `COALESCE(institution,'') != 'Mercury'`. This bit a published figure once.
- Run the **silent-vendor check** (`references/update-database.md` §3a) as part
  of any review. A recurring obligation that stopped is invisible to every
  spending total, and it is the failure mode with the largest realized cost.
- Copilot expenses are positive, Tiller's are negative — compare `ABS`.

## 8. Reporting

Lead with the answer to the question actually asked. Then the three-tier nut,
then runway with its assumptions, then the blind spots. State the date range and
the exclusions.

**Row-level output and generated artifacts stay out of git** — a deck or
dashboard embedding transactions and vendor names goes in `.context/` or an
external archive, never a commit.
