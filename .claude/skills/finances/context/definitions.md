---
doc: definitions
owner: Steven
last-reviewed: 2026-08-16
update-when: a flow_type is added or retired; a sign convention changes; a new
  join trap costs someone a wrong number; the manual-income arrangement changes
---

# Definitions — the semantic layer

**Read this before any SQL or metric claim.** These are the rules that decide
whether an answer is right, not merely returned.

## Signs

**Tiller stores expenses as negative.** Reporting `SUM(amount)` as "spending"
gives a negative number, or worse, silently nets spending against income.

Use `finance.v_spending.spend_amount`, which is positive. Copilot is the
opposite — its expenses are positive — so when reconciling the two, compare
`ABS()` and never the raw sign.

## Spending is not "money that left"

Transfers between own accounts and credit-card payments move money without
spending it. Counting them inflates spending and can double-count: the purchase
on the card *and* the payment of the card.

Filter on `flow_type`. The standard queries exclude categories containing
`transfer`, but that is a heuristic — verify unusual cases against `flow_type`.

## flow_type vocabulary

| Value | Means |
|---|---|
| `expense` | real outflow |
| `earned_income` | wages, consulting revenue |
| `investment_income` | dividends, interest, gains |
| `refund_reimbursement` | money back on a prior outflow |
| `internal_transfer` | between own accounts — not spending |
| `credit_card_payment` | paying a card — not spending |
| `investment_activity` | contributions/withdrawals, not income |
| `cash_withdrawal` | ATM and similar |
| `adjustment` | corrections |
| `needs_review` | **could not be resolved from evidence** |

`needs_review` rows live in `gold.transaction_flow_review`. **Never silently
coerce them into income or transfers.** Report them as unresolved. A recurring
family distribution once sat in `needs_review` and was therefore counted as
income nowhere — understating household income by $12k/year until someone looked.

## Income: the manual-income rule

Some income never touches a bank feed and is tracked by hand in
`finance.manual_income` (surfaced by `finance.v_manual_income`).

**Any income answer must add these lines**, prorated by the range
(`monthly_amount × months_in_range`).

The part that looks like a bug and is not: Hannah's Kinship paycheck already
appears in the mirror as earned income, but that is her **take-home, already net
of her 401(k) deferral**. So the `employee_deferral` line is *additive*, not a
double-count. It would only double-count if a **gross**-pay figure were ever
added instead. The `employer_match` line never touches the accounts at all and
is always net-new.

## gold vs finance

- **`gold.*`** — the analysis models. Deduplicated, vendor-resolved, canonical
  flow type, category typology. **Prefer these.**
- **`finance.*`** — balances, net worth, the classified transaction view, and
  the manual/off-mirror tables.
- **`tiller_raw.*`** — external tables over the Google Sheet. Upstream, never
  written, and deliberately unreachable from the door.

## Join traps

- **`institution != 'Mercury'` silently drops NULL-institution rows.** In SQL,
  `NULL != 'Mercury'` is NULL, not true, so those rows vanish from the result
  without any error. Use `COALESCE(institution,'') != 'Mercury'`. This has
  already produced one wrong published figure.
- **Never match transactions on the card mask.** Masks diverge between Tiller
  and Copilot. Match on absolute amount + date (±4 days) + normalized
  `account_name` — see `docs/runbooks/source-reconciliation.md`.
- **Category labels are source-specific.** Join through `gold.category_aliases`
  to reach the canonical typology rather than trusting a raw `source_category`.
- **Amortized and real-cash spending must never be summed together.** They are
  two views of the same money; adding them double-counts the commitment in the
  month it is actually paid.

## Epics

`gold.epics` holds trips, renovations, celebrations — bounded projects. A large
purchase is **not** an epic; it stays in the category model. `gold.epic_transactions`
links Copilot assignments to Tiller transactions only on a unique date +
absolute-amount + account-suffix match; **unlinked rows still count toward epic
totals**, so an epic total is not the sum of its linked rows.

## Required disclosures

Every answer states the **date range** and whether **transfers, refunds, income,
and uncategorized** transactions were included or excluded. An answer without
these is not finished.
