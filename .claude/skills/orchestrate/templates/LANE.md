<!-- Lane brief template. The orchestrator writes one of these per lane at
     orchestration/<program>/lanes/NN-<lane>.md and COMMITS it. The approver
     pastes a four-line pointer to it, never the file body — a pasted prompt goes
     stale the moment the orchestrator revises it.

     Every repo-specific value below comes from orchestration/PROFILE.md. Fill it
     from there; do not invent a second version of the gate, the ladder, or the
     approval surface.

     Delete any section whose ceremony is not switched on for this lane (see
     SKILL.md → "Ceremonies, and what switches them on"). Do not delete
     sections 1, 2, 3, 7, 8, 9, 10, 11 — those are unconditional. -->

# Lane NN — <lane name>

**Program:** <program-slug> · **Branch:** `<branch>` · **Base:** `origin/<default-branch>` (must contain `<sha>`)
**Kind:** workspace | subagent-fanout · **Depends on:** <lane ids, or "nothing">

---

## 1. Ownership

You own the <domain> <activity> lane of <program>. Repository: `<repo>`.
Create and work on branch `<branch>` from latest `origin/<default-branch>` (must
contain `<sha>`). **You are the only writer in this lane.** An orchestrator in
another workspace owns integration and every shared file.

Peers running concurrently: <lane N on branch X is doing Y; lane M …>. You do not
coordinate with them directly — everything crosses through the orchestrator.

**This file is authoritative.** If it has been revised since you started, re-read
it. It outranks anything you remember from a previous session.

## 2. Read completely before acting

<5–10 exact paths, in reading order. Label consumed interfaces inline.>

- `orchestration/PROFILE.md` — the repo's gates, ladder, shared files, approval
  surface, and frozen contracts **(treat as frozen)**
- `<path>` — <why> **(your consumed interface — treat as frozen)**
- `<path>` — <why>
- Project memories to load: <memory slugs>

**Do not trust** <named stale docs> for current state — <why they're stale>.
Authoritative current state is <the one place>.

## 3. Scope

**You own (may edit):**
- `<glob>`
- `<glob>`

**You must NOT edit:** every shared aggregator in `orchestration/PROFILE.md` §3,
every frozen contract in §6, and <sibling lanes' globs>. The only exception is a
file §3 lists as a *mandated exception*, edited under exactly the discipline
stated there. **Report all other required shared-file changes in your handoff
instead** — see §9.

`orchestration/<program>/lanes/NN-*.md` is orchestrator-owned. You do not edit
your own brief.

## 4. GRANTED APPROVALS  (<approver>: edit before pasting)

- **A1 GRANTED:** <exact bounded external action, and its target>
- **A2 NOT GRANTED**

**No other external approval exists.** Every action listed in
`orchestration/PROFILE.md` §4, and every rung of the §2 ladder beyond the one this
lane is building toward, is explicitly **NOT** approved and must each be requested
separately, with evidence. **No step inherits authorization from the previous
step.**

## 5. External-action boundary

Read-only inspection of live systems and dry runs are allowed. You may create
**isolated scratch resources you own**. You must NOT perform anything on the
profile §4 list without a numbered grant above, and nothing at all under §4's
hard bans. Branch + draft PR only; never push the default branch.

Flag non-trivial spend before incurring it. If this lane is a long-running batch,
§7 must name its checkpoint/resume contract — two workspaces were interrupted
mid-task by a spend limit and could not resume.

## 6. Locked semantics — do not reopen without new contradictory evidence

<numbered list of ratified decisions this lane must implement, not relitigate>

## 7. Objectives, in order

1. <objective> — evidence that closes it: <exact command / artifact>.
   STOP and escalate if <condition>.
2. …

**Fan out.** Any independent sub-work here — parallel file reads, per-item
research, independent test authoring, per-case verification sessions — must go to
concurrent sub-agents. Keep ordered migrations, approval gates, and anything that
mutates shared state sequential.

**One implementation detail to VERIFY, not guess:** <the fact that must be
checked against the live system>. Do not hardcode a guess. <Why: the counterfactual
damage.> The last time this instruction was given, the assumption turned out
inverted and a guess would have silently destroyed data while passing every unit
test written against it.

## 8. Completion loop

Repeat until every acceptance criterion has concrete evidence:

> inspect evidence → plan the bounded change → implement → run focused repository
> checks → run permitted read-only checks against the live system → inspect the
> diff and results adversarially → repair → rerun.

**Code existing is not DONE.** You are done only when every stated check has
concrete evidence — an exact command and its verbatim output.

**Your acceptance gate** — authored by the orchestrator from
`orchestration/PROFILE.md` §1; you may not weaken it, and you may not substitute
a command of your own:

```bash
<exact command(s), copied from the profile's gate table>
```

<Any known-bad baseline from profile §1 that this gate deliberately excludes.>

## 9. Escalation

Escalate for: contract-breaking findings, ambiguity in meaning or ground truth,
acceptable-risk calls, wanting to change anything outside §3, and every approval
in §4.

**State the evidence, recommend ONE direction, and give the smallest concrete set
of alternatives with their consequences. Do not ask anything answerable from the
repo, read-only data, or a test.**

Write it to `orchestration/<program>/escalations/ESCALATION-<date>-<topic>.md`,
commit it on your branch, and tell <approver> it is there. **Do not make the
change.** Continue on whatever is not blocked while you wait.

## 10. Handoff — what you return

Commit on your branch as `docs/HANDOFF-<date>-<lane>.md`, containing:

workspace and branch; HEAD commit; confirmation the branch is pushed; owned
changes; external actions performed, **each with its approval**; gate commands and
real checks **with exact results**; current position on the profile §2 ladder;
unresolved questions; known risks; shared-file changes requested; exact next
dependency; and **SAFE TO INTEGRATE** or **NOT SAFE TO INTEGRATE** — followed by a
sentence naming everything that verdict does *not* authorize.

Also note any observation that changes the design of <downstream planned work>.

## 11. Finish

Commit and push everything. **Do not leave decisions only in an ignored scratch
directory** (`.context/` and the like) — it dies with the worktree.

Report honestly: what is done with evidence, what is blocked and on whom, what you
deferred and why.
