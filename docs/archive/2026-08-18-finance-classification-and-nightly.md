# ARCHIVE — Finance classification pipeline + nightly agent — 2026-08-18

> **Audience:** the next human or Claude agent who opens this branch cold.
> Read this top-to-bottom; it is the canonical record of what this workspace did.
> Everything below reflects the state at archive time.

- **Workspace:** kyiv (Conductor worktree — now archived/deleted)
- **Branch:** `finance-reconcile` → MERGED to main (content landed via PRs #14–#23)
- **Status at archive:** DONE / merged — one open loop, tracked as `kyiv-3bj`

## What this did & why

Started as "expand `gold.vendor_category_map`", the merchant → category lookup.
Two things turned it into something larger. First, the map was an **orphan**:
seeded on 2026-08-11, grown with real tooling, and **consulted by nothing** — the
wiring had been deliberately deferred and never done, so a session's worth of
mapping changed no output at all. Second, once the map was wired in and the
numbers could be trusted, two production defects surfaced that had been quietly
wrong for months.

The outcome: classification now has exactly one precedence chain, the merchant map
drives 84.7% of expense spend (up from 68.5%), net worth is no longer understated
by $526k, and a nightly launchd pipeline rebuilds the mirror and runs an
autonomous finance agent over it.

## Key changes

- `sql/gold.sql` — wired `vendor_category_map` into classification. One chain:
  **per-txn override > vendor_category_map > rule > Copilot (reviewed) > Tiller**.
  Also removed the Copilot "refine within same parent" join, which had become a
  second invisible source of truth *overriding* the map (93 txns / 25 merchants
  rendered as something other than their explicit mapping), and added the
  `!= 'unclassified'` guard so a declined answer cannot erase a real category.
  Copilot is now bounded by a **date literal (`2026-07-09`)** — Steven reviewed
  its categories historically but has stopped, so newer ones are untrusted. Raise
  that date only after an actual review, never because a newer export was imported.
- `sql/refresh.sql` — fixed `parse_tiller_date`: it tried `'%m/%d/%Y'` before
  `'%m/%d/%y'`, and `%Y` parses `"26"` as the year **0026**. 2,514 balance rows sat
  two millennia in the past, splitting `v_monthly_net_worth` into two timelines and
  reporting **$445,415 against a true $971,749**.
- `queries/vendor-category-candidates.sql` — became the classification review
  queue: population defined by `classification_source`, ranked by **spend** not
  count, with a `suggested_action` vocabulary (alias / promote / map / SUSPECT /
  review / accept) and variant detection.
- `queries/classification-sources.sql` — the metric this all exists to move: the
  **tiller share of expense spend**.
- `scripts/nightly-sync.sh` + `scripts/com.stevenjacobs.finance-nightly.plist` —
  3am pipeline: `deploy.sh` → `validate.sh` gate → autonomous `/finances` agent.
- `scripts/add-vendor-category.sh`, `scripts/add-vendor-alias.sh` — `--batch` now
  issues **one** `MERGE` instead of one BigQuery job per row.
- `.claude/skills/finances/` — the procedure, Steven's standing rulings, the
  amortization recipe, and the accounts not to re-flag.
- `requirements-dev.txt` — the door's tests could not be run at all before this.

## Current state

- **Deployed and validated**, 13 deploys, conservation invariant asserted every
  time: row count and total expense spend unchanged, only category distribution
  moved. Final: 8,730 txns / $532,775 expense spend.
- **Classification sources:** vendor_map 88.2% of expense txns (84.7% of spend,
  633 merchants) · rules+overrides 0.5% · Copilot 2.7% · **Tiller 8.5%**.
  Baseline before this work: 8,660 rows, and Tiller carried 20.2% of spend.
- **The Tiller share has a floor.** What remains is ~99% one-off merchants (~1.0
  txn each). Driving it lower would mean mapping one-offs, which is the one thing
  not to do — a mapping applies confidently to every future transaction and
  nothing flags it. Everything ≥$300 has been human-reviewed.
- **Nightly job installed and armed.** Its first autonomous run (2026-08-18)
  succeeded and was independently audited: 13 aliases, 4 mappings, 5 overrides,
  all verified against BigQuery, working tree untouched. It found a real defect on
  its own — Copilot using "School" as a junk drawer, wrong 12 for 12.
- **Door tests pass:** 49 passed, 1 skipped.

## Next steps / open loops

- [ ] **`kyiv-3bj` (P1) — the 3am job fails on gcloud reauth.** `bq` dies with
      "Reauthentication failed. cannot prompt during non-interactive execution."
      Steven's user credential needs periodic reauth; interactive sessions satisfy
      it silently, unattended ones cannot. **Data freshness is NOT affected** — the
      hourly BigQuery scheduled query runs server-side and keeps `gold.transactions`
      current; what is lost is the nightly agent review. Fix is a service account:
      create it, grant BigQuery Job User + Data Editor, **share the Tiller Google
      Sheet with its email** (the step people miss — the rebuild reads the sheet),
      then `gcloud auth activate-service-account`. Sheets-backed external tables via
      a service account need the Drive scope wired correctly and that part is
      fiddly. Steven executes the IAM and sheet-sharing steps.
- [ ] Optional: the other write scripts (`add-rule`, `add-override`,
      `add-vendor-override`, `add-flow-override`) still do one job per row. Only
      worth doing if a session starts using them heavily.

## How to resume

```bash
cd ~/conductor/repos/personal
bd ready                 # surfaces kyiv-3bj with the full procedure
bd show kyiv-3bj
```

Verify any change to the nightly job with `launchctl start
com.stevenjacobs.finance-nightly` — **not** a shell run. An interactive shell
hides exactly the variables that break under launchd; that is how three separate
failures were found (empty PATH, missing USER/LOGNAME for the Keychain, and a
variadic `--allowed-tools` swallowing the prompt).

Read next: `.claude/skills/finances/references/vendor-mapping.md` (procedure +
Steven's standing rulings) and `context/accounts.md` (accounts already ruled on —
do not re-flag them; he has been asked more than once).

Watch `./scripts/query.sh queries/classification-sources.sql` for the trend.
Workspace:    /Users/stevenjacobs/conductor/workspaces/personal/kyiv
Branch:       finance-reconcile
Project dir:  /Users/stevenjacobs/.claude/projects/-Users-stevenjacobs-conductor-workspaces-personal-kyiv
Sessions:     2
Archive dest: /Users/stevenjacobs/Library/Mobile Documents/com~apple~CloudDocs/conductor-archives/kyiv-2026-08-18

## Session transcripts

Archived to `/Users/stevenjacobs/Library/Mobile Documents/com~apple~CloudDocs/conductor-archives/kyiv-2026-08-18/transcripts/` on 2026-08-18 (branch at capture: `finance-reconcile`).
Original live path: `/Users/stevenjacobs/.claude/projects/-Users-stevenjacobs-conductor-workspaces-personal-kyiv`
(may be reused by a future workspace of the same name).

| Session ID | Msgs | Size | First activity | Last activity |
|---|---|---|---|---|
| `493a4a8f-88ef-436a-9be3-cbd36183378b` | 1960 | 5.6M | 2026-08-17T16:09:29.492Z | 2026-08-18T10:37:34.978Z |
| `69223f61-b38a-4a0d-95d9-a5b95f0fc12a` | 1479 | 3.9M | 2026-08-15T20:20:19.358Z | 2026-08-17T15:42:41.632Z |

_To replay a session for debugging:_ `cat "/Users/stevenjacobs/Library/Mobile Documents/com~apple~CloudDocs/conductor-archives/kyiv-2026-08-18/transcripts/<session-id>.jsonl" | jq -r 'select(.type=="user" or .type=="assistant")'`
