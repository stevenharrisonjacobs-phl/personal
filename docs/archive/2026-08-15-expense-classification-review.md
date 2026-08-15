# ARCHIVE — Expense classification cleanup, amortization/projection, and the mobile-access decision — 2026-08-15

> **Audience:** the next human or Claude agent who opens this branch cold.
> Read this top-to-bottom; it is the canonical record of what this workspace did.
> Everything below reflects the state at archive time.

- **Workspace:** puebla (Conductor worktree — now archived/deleted)
- **Branch:** `expense-classification-review` → pushed to origin, **no PR yet** (6 commits ahead of `main`)
- **Status at archive:** WIP — classification/amortization/projection work is done & live in BigQuery; the daily-skill build is the next stage (not started)

## What this did & why

Started as "turn my cash-flow/burn-rate work into a skill" and became a deep cleanup of how the personal finance mirror **classifies** transactions. Core outcome: a **vendor → category lookup layer** so a merchant can never be split across categories again, plus **cost attributes** on categories (so the monthly nut generates from the model, not a hardcoded script), an **amortization** layer (spread big one-offs explicitly), and a forward **projection** layer (assumptions, tax accruals). The last stretch resolved *how to reach all this from a phone*: the answer is native Claude Code features (**Remote Control** + the official **iMessage channel**), not a custom watcher — so a half-built custom texting agent was deleted.

## Key changes (the 6 commits, oldest→newest)

- `9ac3ae0` — **vendor→category lookup, cost attributes, classification cleanup.** New `gold.vendor_category_map` pins each canonical vendor to one category and wins over the noisy per-txn upstream category. New `Childcare` category; `scripts/add-vendor-category.sh`. Split vendors went 29 → ~1. Fixed a real bug: the `target` vendor regex was matching "Vanguard Target Retirement" and filing ~$76k of 401(k) activity under vendor *Target*.
- `e9619d9` — **amortization:** `amortization_schedule` table, `v_spending_amortized`, and the `/amortize` skill. Conservation invariant (real vs amortized totals) holds exactly.
- `400025c` — **projection layer:** `finance.assumptions` (effective-dated, e.g. the 37% tax rate has a recorded rationale), `finance.accruals` (pre-amortization tax accrual), `gold.v_projection` (18 months forward). The accrual surfaced **$6,610 of unreserved 2026 tax liability**.
- `5468415` — **dropped category `cadence`** (it was smearing 133 sub-$100 charges across 12 months each — wrong grain). Spreading is now explicit-only via `/amortize`. Kept `cost_behavior` and `essential` on `gold.categories`.
- `9bf526c` — **scheduled Fitler annual dues** $8,200 → $683.33/mo across 2026; noted club consumption is not amortizable.
- `b59364d` — **split Fitler Club:** dues (≥$1,000) → Fitness; everything else (club food) → Restaurants & Bars, via amount-conditioned `finance.classification_rules` (`add-rule.sh` now exposes min/max amount). ~$2,800/yr of club dining moved out of "gym."

## Current state

- **Live in BigQuery now** — everything downstream of the raw feeds is a *view*, so these changes took effect on read with no backfill. `validate.sh` last passed at 8,660 txns, review queue 0; conservation exact ($521,945.53 both sides).
- ⚠️ **NOT merged to `main`.** The finance mirror's `deploy.sh` re-seeds `gold.sql`/`model.sql` from `main` — so **a deploy from `main` will revert all of this** until the branch is merged. This is the single most important durability risk. (Documented behavior; see AGENTS.md.)
- **Mobile-access decision is settled** (research only, no code): use **Remote Control** (`claude --remote-control` on the always-on Mac mini → drive from the Claude app's Code tab) for full repo+skills access with local gcloud/BigQuery intact; use the official **iMessage channel** plugin (`/plugin install imessage@claude-plugins-official` → `claude --channels plugin:imessage@claude-plugins-official`) for text-a-question. Prereqs verified on the mini: claude v2.1.228 supports `--remote-control`, signed into claude.ai (no API key), Bun 1.3.14 present.
- **Deleted this session:** `scripts/imsg_send.py`, `imsg_watch.py`, `texting-agent.sh` — a custom chat.db watcher, made redundant by the native features above. (Recoverable from the session transcript if ever wanted.)

## Next steps / open loops

- [ ] **NEXT STAGE (the reason for a new workspace): build the daily finance skill** — pull → resolve → classify → **report to Steven** + amortization recommendations. Runs locally (needs the `steven@plumgrowth.ai` gcloud identity). Auto-applies only the safe deterministic clears; **recommends-only** for new vendors/anomalies/amortization (AGENTS.md: "never apply suggestions automatically"). Deliver the "text me / reply to me" half via the **native iMessage channel**, not a custom watcher. Fold in the long-deferred **recurring-payment-gone-quiet monitor** (the check that would have caught the missed mortgage).
- [ ] **Merge this branch** (or open a PR) so the classification work survives a `deploy.sh` from `main`. Highest-priority durability action.
- [ ] **Apply the flow-review labels** in `context/flow-review-labels.md` (preserved in the iCloud archive) — Steven's manual income-vs-transfer decisions incl. the durable rule "anything in/out of a BROKERAGE account = internal transfer" and the recurring $1,000/mo Kasperzak Family Distribution = income. Confirm which are already applied as flow-overrides vs still pending.
- [ ] Precedence reorder: a per-transaction category override should beat the blanket `vendor_category_map` (currently the vendor map shadows it) — one-line COALESCE change.
- [ ] Split-vendor guard view (nothing currently watches for a vendor drifting across categories — that's how the whole mess was found by accident).
- [ ] PR #6 still open (per prior notes).
- [ ] **Real-world (not code):** 🔴 mortgage 3 payments missed (June crosses 90-day delinquency ~Aug 30); 🔴 Q3 estimated taxes due Sep 15, $0 reserved.

## How to resume

```bash
# From a fresh workspace on this repo:
git fetch origin && git checkout expense-classification-review   # or branch from main after merge
# Read this file, then the two skill references that define the current model:
#   .claude/skills/finances/references/cash-flow-review.md
#   .claude/skills/finances/references/spending-check.md
#   .claude/skills/amortize/  (SKILL.md)
# Sanity-check the mirror is healthy:
./scripts/validate.sh
# Next-stage design notes live in the newest session transcript (278b6e26…) — the
# daily-skill design + the Remote Control / iMessage channel research.
```

**Preserved artifacts (iCloud, row-level so NOT in git):**
`~/Library/Mobile Documents/com~apple~CloudDocs/conductor-archives/puebla-2026-08-15/`
— `transcripts/` (4 sessions) and `context/` (the two HTML breakdowns: `july-2026-breakdown.html`, `vendor-classification.html`; `flow-review-labels.md`; and all the analysis `.sql`/`.json`). iCloud syncs to the other Mac on the same Apple ID.

<!-- Session transcripts manifest below -->

## Session transcripts

Archived to `~/Library/Mobile Documents/com~apple~CloudDocs/conductor-archives/puebla-2026-08-15/transcripts/` on 2026-08-15 (branch at capture: `expense-classification-review`).
Original live path: `~/.claude/projects/-Users-stevenjacobs-conductor-workspaces-personal-puebla` (may be reused by a future workspace of the same name).

| Session ID | Msgs | Size | First activity | Last activity |
|---|---|---|---|---|
| `278b6e26-00fa-46ea-a06d-3f399300459c` | 256 | 2.0M | 2026-08-14T23:30:28Z | 2026-08-15T20:09:39Z |
| `2d3fa55b-63af-4038-b9be-38662638ad32` | 509 | 1.3M | 2026-08-11T20:01:54Z | 2026-08-11T21:40:18Z |
| `63c30935-449c-4ce2-9338-39dbc5060b2f` | 1119 | 3.1M | 2026-08-11T21:40:20Z | 2026-08-14T23:28:41Z |
| `933f60b5-1a37-4366-b280-8ce5d0321917` | 9 | 28K | 2026-08-15T12:58:36Z | 2026-08-15T12:58:38Z |

_Replay for debugging:_ `cat "<archive>/transcripts/<session-id>.jsonl" | jq -r 'select(.type=="user" or .type=="assistant")'`
