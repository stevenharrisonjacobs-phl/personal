# ARCHIVE — Household cash-flow review + income-classification fix — 2026-08-11

> **Audience:** the next human or Claude agent who opens this branch cold.
> Read this top-to-bottom; it is the canonical record of what this workspace did.
> Everything below reflects the state at archive time.

- **Workspace:** seattle (Conductor worktree — now archived/deleted)
- **Branch:** `september-childcare-budget-model` → open PR #6
- **Status at archive:** code change DONE and applied to BigQuery; analysis complete; several real-world action items still open (see Next steps)

## What this did & why

Steven left his W-2 role on 15 March 2026 and started a consultancy (Plum Growth).
The presenting question was narrow — *can we afford $10,000 to paint the house?* —
but answering it properly meant reconstructing the household's whole cash-flow
picture from the Tiller→BigQuery mirror.

The answer was yes: $10k is ~2% of liquid + investable assets. The more useful
findings were the ones the question didn't ask for — a structural monthly gap, an
unreserved tax liability, and **three unpaid mortgage payments that nobody had
noticed**. Along the way the analysis surfaced a genuine defect in the mirror's
flow-classification model, which is what PR #6 fixes.

## Key changes

- `sql/gold.sql` — adds `flow_recurring_family_income` to the `evidence` CTE and
  branches on it in `flow_type`, `flow_reason` and `flow_confidence`. A recurring
  $1,000/month inflow (a distribution from Hannah's father, 19 consecutive
  payments since Jan 2025) arrives labelled `Transfer to Hannah Kasperzak`, so the
  model routed it to `needs_review` (18 rows — Copilot tagged them income but the
  model only promotes income-tagged inflows on a known-source allowlist of
  Bobsled / Newco / `payroll`) or `refund_reimbursement` (1 unpaired row). It was
  therefore counted as income **nowhere**, understating household income by
  $12k/year. Keyed on description rather than `vendor_name` so it survives vendor
  renaming; computed once in the CTE so the three parallel CASE branches can't drift.
- `gold.vendor_rules` (data, not code) — new rule `kasperzak-family-distribution`
  renames the vendor to "Kasperzak Family Distribution" so the misleading label
  that caused the bug can't cause it again. Survives redeploys: the seed MERGE in
  `gold.sql` has no `WHEN NOT MATCHED BY SOURCE` delete clause.

## Current state

- **PR #6 is open**, not merged. The change was applied to BigQuery directly by
  running `sql/gold.sql` alone (`gold.transactions` is a view, so it recomputes on
  read — a full `deploy.sh` would have rebuilt the Tiller external tables and
  rewritten the scheduled query unnecessarily, and this workspace's `.env` lacks
  `TILLER_SHEET_ID`). **Live BigQuery and this branch are in sync.**
- **Verified by regression** over the Aug 2025+ window: `earned_income` +13 rows /
  +$13,000; `needs_review` −12; `refund_reimbursement` −1; every other `flow_type`
  byte-identical. The unrelated "Dean Kasperzak Dinner" expense is correctly
  untouched. `./scripts/validate.sh` passes — 8,636 transactions, 8,636 distinct
  keys, flow review queue down from 37 to 18.
- **Analysis artifacts are NOT in git** and never should be: an advisory deck and
  an interactive dashboard, the latter embedding 6,765 row-level transactions and
  1,512 vendor names. Per `AGENTS.md` ("never commit exported transactions or
  query results — this repo pushes to GitHub") they live only in the external
  archive — see *How to resume*.

## Next steps / open loops

- [ ] **Mortgage arrears — time-critical.** No mortgage payment has left any
      tracked account since 4 May 2026. Steven confirmed this is real: ~$10k owed
      (3 × $3,173.53 plus late fees). June's payment tips past 90 days delinquent
      around 1 Sep 2026, which is a materially worse credit event than 60. Call
      PNC: get the reinstatement figure, ask what's been furnished to the bureaus,
      request a goodwill adjustment (PNC ran $0.50 account-verification deposits
      against Waterford Checking on 22 May — evidence an autopay enrolment was in
      flight and failed), and re-establish autopay in writing.
- [ ] **Connect the mortgage funding account to Tiller.** Ten institutions are
      linked; PNC is not one of them. Until it is, ~$38k/year of outflow is
      invisible to the mirror and every forecast has to assume it.
- [ ] **2026 estimated taxes — none paid.** Plum Growth nets roughly $91.5k of
      self-employment income for 2026; at 35–40% that is ~$32–37k owed, of which
      $0 has been paid or reserved. Q1 and Q2 are missed; Q3 was due 15 Sep 2026.
      Needs a CPA, particularly for the Philadelphia BIRT/NPT treatment.
- [ ] **Bruce's aftercare is absent from the data.** Searched 12 months for
      aftercare / extended-day / YMCA / childcare vendors — nothing recurring. The
      only Chester Arthur item is a $237 donation; the ~$375/mo of sitters is
      evening babysitting by name. Models carry $650/mo as a labelled placeholder.
      Get the real figure and re-run.
- [ ] **Build the missing-recurring-payment monitor.** Offered, not built. The
      mortgage stopping for three months should have been caught automatically:
      for any vendor hitting ≥6 of the last 12 months at a consistent amount, flag
      it when it goes quiet past its usual window. ~30 lines in
      `sql/reviewer.sql` plus a line in the `/finances` update flow. This is the
      systemic fix for the class of failure that produced the arrears.
- [ ] **Two miscategorisations** worth vendor rules: Davey Tree Expert ($328) is
      filed under Clothes & Grooming; Sixt car rental ($344) under Unclassified.
- [ ] **Merge PR #6.**

## Known gaps in the analysis (carry these forward)

- Home value and mortgage balance are not tracked, so all net-worth figures
  exclude both.
- Balance history begins 7 Apr 2026 only; the Aug 2026 jump reflects Mercury and
  the Betterment IRA being connected that day, not a change in wealth.
- Two deposits totalling $44,758 (14 Oct 2025, 7 May 2026, both into Chase Savings
  as "Deposit ID Number") remain unidentified. Whether they recur materially
  changes the forecast.
- **`institution != 'Mercury'` in ad-hoc SQL silently drops NULL-institution
  rows** (48 rows / $2,784 in the 12-month window). Use
  `COALESCE(institution,'') != 'Mercury'`. This bit one intermediate figure during
  the session; published numbers were corrected.
- BigQuery auth (`steven@plumgrowth.ai`) expired near the end of the session and
  cannot re-prompt in a non-interactive run. Run `gcloud auth login` before live
  queries.

## How to resume

```bash
git checkout september-childcare-budget-model
gh pr view 6 --web                      # the code change and its rationale
gcloud auth login                       # BigQuery auth expired at archive time
./scripts/validate.sh                   # confirm the mirror is healthy
```

Then read, in this order:

1. This file — the open loops above are the actual work remaining.
2. `AGENTS.md` — mirror guardrails; note the "never commit row-level data" rule.
3. The analysis artifacts, which are **not in git**:
   `~/Library/Mobile Documents/com~apple~CloudDocs/conductor-archives/seattle-2026-08-11/artifacts/`
   - `finances-2026-08-10.html` — the advisory deck (the balance sheet, the
     monthly nut in three tiers, 2026 real-cash vs amortized views, stress tests,
     recommendations). Open in a browser; it prints cleanly.
   - `finance-dashboard.html` — interactive dashboard, self-contained, no network.
     Five tabs: **Model** (scenario sliders — income, tax reserve, childcare,
     discretionary trim — with live cash projection and runway), **Spending**
     (category → vendor drill-down over any range), **Money in** (income by source;
     the "months paid" column is the reliability test), **Review** (transaction-level
     keep/cut/ask tagging, saved to browser localStorage — was mid-use for a
     six-week spending review), **Accounts**.

   Both embed real balances and, in the dashboard's case, row-level transactions.
   Keep them out of git. To regenerate equivalents, re-run `/finances` → *Analyze*.

The single most important next action is the **mortgage arrears** — it is the only
item on this list with a deadline.

## Session transcripts

Archived to `/Users/stevenjacobs/Library/Mobile Documents/com~apple~CloudDocs/conductor-archives/seattle-2026-08-11/transcripts/` on 2026-08-11 (branch at capture: `september-childcare-budget-model`).
Original live path: `/Users/stevenjacobs/.claude/projects/-Users-stevenjacobs-conductor-workspaces-personal-seattle`
(may be reused by a future workspace of the same name).

| Session ID | Msgs | Size | First activity | Last activity |
|---|---|---|---|---|
| `276c0aa6-bd15-4656-a5eb-94405caa8222` | 824 | 7.7M | 2026-08-10T22:16:29.202Z | 2026-08-11T16:32:56.834Z |
| `e276c826-4016-454c-a72f-8fe8eba79147` | 22 |  84K | 2026-08-10T22:04:04.804Z | 2026-08-10T22:04:13.134Z |

_To replay a session for debugging:_ `cat "/Users/stevenjacobs/Library/Mobile Documents/com~apple~CloudDocs/conductor-archives/seattle-2026-08-11/transcripts/<session-id>.jsonl" | jq -r 'select(.type=="user" or .type=="assistant")'`

The two analysis artifacts (`finance-dashboard.html`, `finances-2026-08-10.html`) are in
`../artifacts/` alongside these transcripts. They are deliberately not committed — the
dashboard embeds 6,765 row-level transactions and 1,512 vendor names.
