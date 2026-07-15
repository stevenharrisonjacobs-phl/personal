---
project: snapfix
area: work
type: client
status: active
repos: [conductor/repos/snapfix, conductor/workspaces/snapfix]
last_touched: 2026-07-15
---

# Snapfix  ·  work / client

Plum Growth's **first client** — AI GTM for a hotel-ops SaaS. People & context:
see [people-and-workstreams.md](../../docs/people-and-workstreams.md) (Brett
Robbins CEO, Ciarian head of sales, Christian head of marketing). Codebase =
`conductor/repos/snapfix` (GCP `snapfix-agents`).

> Sub-projects below were reverse-engineered on 2026-07-15 from GitHub (PRs +
> issues), Conductor worktrees, and `.context` specs — **not** from calls (Granola
> holds no Snapfix meetings). NEXT actions cite live issue/PR numbers. Groom to
> taste — some may merge, and the client-relationship workstream is missing (no
> data source for it yet).

## FOCUS
> **/ask GTM analytics** — land PR #390 (consult transcripts + emails), then stand up the offline eval harness (#379).

## Sub-projects

### /ask — GTM analytics · active  ⭐ front burner
Natural-language sales/GTM analytics over verified call insights + canonical GTM
views. 3 worktrees live on this. Shipped: #371 native /ask, #382 canonical views,
#388 persist eval results, #387 eval-v1 findings.
**NEXT** → Land PR #390 — `/ask` consults transcripts + emails for subjective deal questions.
- [ ] #379 offline eval harness (nightly question→expected-answer set) (added 2026-07-15)
- [ ] #381 targets/quota seed so `/ask` can answer "are we on track?" (added 2026-07-15)

### Fail-loud / system reliability · active
Epics 1–6 (#358–#363): no silent failures, alerting-as-dependency, BQ↔PG sync,
canonical eligibility predicate, entity identity, config/version enforcement.
Worktrees: `system-issues-audit`, `lagos`.
**NEXT** → Land PR #366 (fail-loud spine: sticky rc, alerting dependency, token hydration).
- [ ] ⚠️ #383 CI + drift-gate silently dead since 2026-07-10 — GitHub Actions not creating runs (added 2026-07-15)
- [ ] #364 / #365 capture OpenAI-embedding + web_search token usage for cost monitoring (added 2026-07-15)

### Signals pipeline · active
Detection → lifecycle → Signals Board/Map UI. Shipped a lot (#350–#355 board/map,
owned-account signals). 
**NEXT** → Decide next: #349 GTM presentation layer (lanes/routing) vs #269 signal-lifecycle UI (held branch).
- [ ] #259 signal-card screening thumbs (open PR) (added 2026-07-15)
- [ ] #347 broaden churn detection beyond Renewal-Lost (added 2026-07-15)
- [ ] #296 expand ICP region to include Europe (currently UK + US-East) (added 2026-07-15)

### job_change data quality · active
Big sub-thread (tracking epic #293): role_change/employer_change split, pairwise
resolver, identity gating, Lusha matching, CRM sync. Mostly follow-ups now
(dated ~06-30, going stale).
**NEXT** → 🔴 #288 (priority:high) reverse the ~19 bad job_change CRM writes in HubSpot.
- [ ] #268 job_change → HubSpot CRM sync (held branch, review vs #232) (added 2026-07-15)
- [ ] #283 warehouse MDM: merge multi-domain/name companies into golden entities (added 2026-07-15)

### Outreach agents (plays + drafting) · active
LangGraph outreach v4 → plays → drafting → review queue. Shipped: #327 advisory
send recommendation, #313 v4.0, review-queue versioning.
**NEXT** → Fix #335/#336 — outreach graph swallows mid-run LLM errors (reports success, persists nothing).
- [ ] #314 retire/repoint stale v2 version registry to live v3 (4.0) (added 2026-07-15)
- [ ] #267 Researcher v2.6 recent-signals momentum context (open PR) (added 2026-07-15)

### Call insights / transcript intelligence · active
Extraction quality + 90-day backfill that feeds `/ask`. Context:
`call-insights-quality-reaudit.md`.
**NEXT** → Finish the call-insights v1 quality re-audit + let the 90-day backfill complete.

### Cowork + snapfix-door platform · active
Rep-facing Claude seat: skills, context-doc library (#376), feedback→trace (#372),
the snapfix-door MCP connector. Plugin v0.3.0.
**NEXT** → Fix the door connector OAuth — #386 token expires mid-session / #369 persist OAuth state off Cloud Run.
- [ ] #370 standardize rep login (dual Auth0 identity) (added 2026-07-15)

## LOOSE
Loops not tied to a sub-project.
- [ ] #224 curated content pipeline (claims/announcements/POV) — held branch, decide revive or drop (added 2026-07-15)

## WAITING ON
- _(nobody yet)_

## LOG
- 2026-07-15 — Reverse-engineered 7 active sub-projects from GitHub + Conductor + specs; set FOCUS to /ask.

## ARCHIVE
- [x] Stand up a cross-project tracker / "mandate" layer — **done 2026-07-15** (this tracker is it).
