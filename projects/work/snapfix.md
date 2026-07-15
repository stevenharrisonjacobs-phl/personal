---
project: snapfix
area: work
type: client
status: active
repos: [conductor/repos/snapfix, conductor/workspaces/snapfix]
last_touched: 2026-07-15
---

# Snapfix  ·  work / client

Plum Growth's **first client** — AI GTM for a hotel-ops SaaS. People: Brett
Robbins (CEO), Ciaran (head of sales), Christian (head of marketing). See
[people-and-workstreams.md](../../docs/people-and-workstreams.md). Codebase =
`conductor/repos/snapfix` (GCP `snapfix-agents`). Slack = Plum Growth workspace.

> Three real workstreams (per Steve, 2026-07-15), grounded in Slack threads +
> GitHub. The many GitHub issues/PRs fold in as loops under the right workstream.

## FOCUS
> **Co-work** — get Brett's green light on the cross-team co-work experience (pinged 07-13), then finish the outbound workflow with his 2 outbound people.

## Sub-projects

### 1. Co-work — the team's front door · active  ⭐
**The core idea:** let Snapfix's team use Co-work as the single front door to
everything we've built — accessible + customizable per person, not just Steve's
setup. Stems from Brett's 07-01 Slack note sharing **Zander's** video (Obsidian
"second brain", Digital Sales Rooms, live pricing tool, curated roadmaps,
competitive calculators, auto-CRM-from-transcripts, MEDDPICC artifacts, voice
email, Notion transcript miner). Steve's 07-09 reply: *"we've done the hard part
— data layer, shared context layer, app layer are built."* This is the umbrella
over the GTM-analytics (`/ask`) work **plus** porting existing capability into
Co-work so the team self-serves. Zander's own blocker (and ours): making it
self-serve across a team without the output getting worse.
**NEXT** → Land the cross-team Co-work experience & get the right people from Brett.
**WAITING** → 🔴 **Brett** — reply to 07-13 "hacked a cross-team co-work experience, still a priority?" (since 2026-07-13)
- [ ] Port existing work into Co-work as the front door (outbound, signals, sales-ops tooling à la Zander's DSR/pricing/MEDDPICC) (added 2026-07-15)
- [ ] `/ask` GTM analytics — land PR #390 (transcripts + emails); then offline eval harness #379, targets/quota seed #381 (added 2026-07-15)
- [ ] Stand up 1–2 salespeople with their own AI sales-ops setup (Steve offered to fold into the design partnership) (added 2026-07-15)
- [ ] Fix snapfix-door connector OAuth — #386 token expires mid-session / #369 persist state off Cloud Run; #370 rep login (added 2026-07-15)
- [ ] Call-insights v1 quality re-audit + 90-day backfill (feeds `/ask`) (added 2026-07-15)

### 2. Outbound agent — working, reliable, engaged-with · active
**Get the outbound agent genuinely working and reliable.** The single biggest
challenge is **getting people to engage with the messages**. Current idea:
**pipe generated messages into a Slack channel for review** (lower the friction
to review/approve). Ciaran (07-01) asked for time with his AE/BDRs for feedback.
**NEXT** → Build the "outbound messages → Slack channel for review" flow.
- [ ] Get AE/BDR feedback session with Ciaran's team (he offered 07-01) (added 2026-07-15)
- [ ] Reliability: #335/#336 outbound graph swallows mid-run LLM errors (reports success, persists nothing) (added 2026-07-15)
- [ ] ⚠️ #383 CI + drift-gate silently dead since 07-10; #366 fail-loud spine PR (added 2026-07-15)
- [ ] 🔴 #288 (priority:high) reverse ~19 bad job_change CRM writes in HubSpot (client data) (added 2026-07-15)
- [ ] Signals feed outbound: #349 presentation layer, #269 lifecycle UI, #259 screening thumbs (added 2026-07-15)

### 3. ABM · active  🆕
Christian + Ciaran have **started an ABM effort** and want Steve to plug in
(Christian, 07-13: *"early in the effort… figuring out what we can/should do and
then how to scale"*). Met with Ciaran 07-14. Christian shared **2 completed
target docs** (Google Docs); the **full target list sits with Ciaran**.
**NEXT** → Get the full ABM target list from Ciaran + review Christian's 2 target docs, then define how we plug in.
**WAITING** → **Ciaran** — full list of ABM targets (Christian doesn't have it) (since 2026-07-14)
- [ ] Pull in Christian's 2 shared target docs (Google Docs links in the DM) (added 2026-07-15)
- [ ] Define how Plum Growth's tooling (signals/outbound) plugs into their ABM + how to scale it (added 2026-07-15)

## LOOSE
- [ ] #224 curated content pipeline (claims/announcements/POV) — held branch, revive or drop? (added 2026-07-15)
- [ ] #283 warehouse MDM: golden company entities (foundational, cross-cutting) (added 2026-07-15)

## WAITING ON
- **Brett** — co-work go-ahead (see workstream 1)
- **Ciaran** — ABM target list (see workstream 3)

## LOG
- 2026-07-15 — Restructured to Steve's 3 real workstreams (Co-work / Outbound / ABM), grounded in Slack (Brett Zander note 07-01, Christian ABM 07-13) + GitHub. Superseded the 7 code-derived sub-projects.

## ARCHIVE
- [x] Stand up a cross-project tracker / "mandate" layer — **done 2026-07-15**.
