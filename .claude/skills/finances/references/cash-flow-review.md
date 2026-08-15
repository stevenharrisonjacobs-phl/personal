# /finances → Advisor review (cash flow, burn rate & runway)

A **read-only** financial-advisor workup of the whole household: what a normal
month costs, how fast cash is moving, and how long it lasts under stress. Use this
when the ask is directional ("can we afford X", "what's our burn", "how long does
our cash last", "are we underwater each month") rather than a single lookup — for
one number, use `analyze-data.md` instead.

Never mutate here. If the run surfaces a genuine mirror defect (see *Watch for*),
note it and hand it to the Update branch; don't fix it inline.

## Framing

Model the **household and the business (Plum Growth / Mercury) as one economic
unit** — money is fungible across them. Take a plain-spoken advisor's tone: lead
with the decision, then the structural findings the question didn't ask for. Every
past session found something bigger than the presenting question (a monthly gap, an
unreserved tax bill, three missed mortgage payments). Look for those.

## 0. Freshness & auth first

- Live queries need `steven@plumgrowth.ai` BigQuery auth (it expires between
  sessions and can't re-prompt non-interactively — run `gcloud auth login` if a
  query fails auth). Then `./scripts/validate.sh` to confirm the mirror is healthy.
- Check source freshness (`queries/source-freshness.sql`) — a stale feed silently
  understates recent spend and breaks the burn rate.
- **`balance_history` only begins 7 Apr 2026.** Any net-worth or balance-trend
  jump before that is accounts being *connected*, not wealth changing. State this.

## 1. Establish the balance sheet

Pull `gold.accounts` (signed balance by class/type) and a month-end balance trend
from `finance.balance_history` (`ROW_NUMBER() OVER (PARTITION BY account_id, month
ORDER BY balance_date DESC)`, take `rn=1`). Split into **cash** (checking / savings
/ money market), **taxable investments** (brokerage), **retirement** (401k / IRA),
and **card debt** (liability). Cash + taxable = what's actually available; that's
the denominator for "can we afford X" and the numerator for runway.

Known gaps to state every time: home value and mortgage *balance* aren't tracked
(net worth excludes both); the Betterment IRA + Mercury connected 7 Apr 2026.

## 2. Income — model it, don't just sum it

Take-home income has several streams; separate steady from at-risk:

- **Earned income** from the mirror (`flow_type='earned_income'`), split
  household (`institution != 'Mercury'`) vs business revenue (`institution =
  'Mercury'`). List by source with a **"months paid" count** — that column is the
  reliability test (12/12 = steady; sporadic = at-risk).
- **Off-mirror manual income** (`finance.v_manual_income`) — always add it, prorated
  to the range. See `analyze-data.md` §3a for the double-count caveat.
- **Lumpy deposits** — inflows `> $3,000` tagged `needs_review`. Call these out
  separately; don't let a severance or a one-off deposit inflate the run rate.
- **Tax haircut.** Business revenue is *pre-tax*. For forward projections apply an
  effective rate to the self-employment side (past runs used ~35–40%; the session
  used 37% on `REV - tools`). State the rate. Note whether the deck shows income
  gross or net of a tax reserve — past deck deliberately showed **gross** at
  Steven's request, with the reserve broken out as a liability instead.

## 3. The monthly "nut" — three tiers

The core reusable artifact. Reconstruct what a normal month costs, in three tiers,
over a trailing 12-month window (and cross-check against a trailing 4-month
post-transition window — spending changed after the 15 Mar 2026 job exit):

1. **Fixed** — same every month: mortgage, groceries, healthcare/pharmacy, home
   insurance, transportation, cleaning, baseline unclassified.
2. **Committed (amortized)** — real but lumpy; **spread annual charges across the
   year** per Steven's standing instruction (e.g. Fitler Club annual + monthly,
   streaming/subscriptions, martial arts, Peloton, evening sitters).
3. **Seasonal** — shape each forward month from **last year's same month**, not a
   flat average (utilities, restaurants, travel, gifts, clothes/Amazon all swing
   seasonally). Use `EXTRACT(MONTH ...)` to find vendors active only in the school
   year (Sep–May) vs summer.

Childcare is its own line and time-varying: Beacon/Brightwheel (Ada) resumes each
September; Tall Pines (summer camp) goes to zero in fall; Bruce's aftercare is a
separate figure — **it is NOT in the mirror** (searched 12 mo, nothing recurring),
so carry it as a labelled placeholder and ask for the real number.

**Core burn** = spend excluding business (`COALESCE(institution,'') != 'Mercury'`)
and excluding `Internal Transfer`, `flow_type='expense'`. Report total, avg/mo, and
median/mo over the 12-mo window.

## 4. Two views of the year: real cash vs amortized

Show 2026 both ways — Jan→now **actual** from the mirror, rest of year
**projected** on the current plan:

- **Real cash** — money as it actually moved. Violent: severance, a big deposit, a
  quarterly tax payment, the annual Fitler bill all land as single events.
- **Amortized** — the same year with those lumps spread over their period of use.
  This is the line that tells you what a normal month costs.

Present as a cumulative running total from $0 on 1 Jan. The gap between the two
lines is the story.

## 5. Stress-test → runway

Runway = available cash (cash + taxable, or cash alone for a conservative floor) ÷
monthly gap. Build a scenario table varying the at-risk income and discretionary
trim. The session's scenarios, as a template:

- Base (all contracts hold)
- Snapfix (design-partnership client) doesn't repeat
- Primary contract (Bobsled) ends, Snapfix continues
- Both contracts end — one spouse's income only
- Contract ends **and** cut ~$4k/mo
- Contract ends **and** live at the nut + $2k breathing room

Report months-to-zero for each, and the calendar date cash hits zero. Distinguish
"cash gone" from "cash + investments gone."

## 6. Watch for (these bit during the original run)

- **The NULL-institution trap.** `institution != 'Mercury'` silently drops
  NULL-institution rows (48 rows / ~$2.8k in the 12-mo window). Always
  `COALESCE(institution,'') != 'Mercury'`.
- **A recurring payment that went silent.** The mortgage stopped leaving every
  account after 4 May 2026 and nobody noticed — three missed payments, ~$10k + late
  fees, a credit event. For any vendor hitting ≥6 of the last 12 months at a
  consistent amount, **flag it when it goes quiet past its usual window.** This is
  the single highest-value check; run it every time. (A permanent monitor in
  `sql/reviewer.sql` was scoped but not built — offer it.)
- **Unidentified lumpy deposits** materially change the forecast — surface them,
  don't absorb them into the run rate (e.g. two "Deposit ID Number" deposits into
  Chase Savings totalling ~$44.8k remain unexplained).
- **Untracked outflow accounts.** PNC (the mortgage account) isn't linked to
  Tiller — ~$38k/yr invisible. Any account not in the mirror means the forecast is
  assuming, not measuring. Say so.

## 7. Deliverables

Two artifacts, both **self-contained, no network, and kept OUT of git** (they embed
real balances and row-level transactions — per `AGENTS.md`, never commit row-level
data). Write them to `.context/` and, if archiving, copy to the external archive.

1. **Advisory deck** — balance sheet, the three-tier nut, the two 2026 views,
   stress tests, recommendations. Prints cleanly.
2. **Interactive dashboard** — five tabs: **Model** (scenario sliders: income, tax
   reserve, childcare, discretionary trim → live projection + runway), **Spending**
   (category → vendor drill-down over any range), **Money in** (income by source
   with the months-paid reliability column), **Review** (per-transaction keep/cut/ask
   tagging saved to localStorage), **Accounts**.

Reference templates from the original run live at
`~/Library/Mobile Documents/com~apple~CloudDocs/conductor-archives/seattle-2026-08-11/artifacts/`
(`finances-2026-08-10.html`, `finance-dashboard.html`) — read them for structure,
regenerate fresh against current data. Use the `dataviz` skill for any charts.

## 8. Required disclosures (same as analyze-data §5)

State the **date range**; whether **transfers, refunds, income, and uncategorized**
were included or excluded; the **tax rate** assumed; and every placeholder (e.g.
Bruce's aftercare) as a placeholder. Prefer aggregates; don't print full account or
transaction IDs. Never invent a category — if classification is uncertain, show a
short merchant summary and ask.
