<!-- Program plan template. The ORCHESTRATOR writes this once, at
     orchestration/<program>/PLAN.md, BEFORE writing any lane brief — the lane
     table here is what lanes.json and lanes/NN-*.md are generated from. Commit
     it. Revise it in place when scope changes; lanes read the committed file,
     so a revision reaches every workspace without a re-paste.

     Every repo-specific value — gate commands, ladder rungs, shared aggregators,
     the irreversible-action list, review lenses, frozen contracts — comes from
     orchestration/PROFILE.md. Cite it; do not restate it differently.

     Nothing in this document grants authority. Approvals live in §5 and are
     granted only by the approver editing a lane brief's §4. -->

# <Program name> — program plan

**Program:** `<program-slug>` · **Date:** <YYYY-MM-DD>
**Orchestrator branch:** `<branch>` · **Base:** `origin/<default-branch>` at `<40-char sha>`
**Profile:** `orchestration/PROFILE.md`, last verified `<YYYY-MM-DD>`
**Standing:** false | true (if true, `orchestration/CURRENT.md` must point here)

---

## 1. Why this, why now

<2–5 sentences. What is broken or missing, what becomes possible when it lands,
and what depends on it downstream. Name the one thing that makes this a program
rather than a task: more than one judgment stream, an irreversible or external
action, or more than one lane touching the same shared file.>

**Prerequisite:** <the program or gate that must close first, or "none">.

## 2. Frozen contracts

Start from profile §6. These are pinned at the SHA below and are **consumed as
frozen** from the moment this plan is committed. Consumers build against them
immediately — never "audit-only", never idle waiting for the producer to certify.
A contract change is an escalation the orchestrator fans out, not a reason for a
lane to stop.

| Artifact | Owner | Consumers | Frozen at |
|---|---|---|---|
| `<path>` | lane <NN> | lanes <NN, NN> | `<sha>` |
| `<path>` | orchestrator | all lanes | `<sha>` |

## 3. Lanes

| Id | Scope | Kind | Start condition |
|---|---|---|---|
| 01 | <one sentence, end-to-end> | workspace | <artifact condition, e.g. "this plan is committed"> |
| 02 | <…> | workspace | after lane 01's `<contract path>` is frozen (**not** full certification) |
| 03 | <…> | subagent-fanout | after `<artifact>` exists at a pushed tip |
| 04 | independent adversarial review | subagent-fanout (orchestrator's) | stable pushed tips for lanes <NN, NN> |

**Start conditions are artifact conditions, never calendar ones.** "After lane
01's contract is frozen" is a start condition; "after lane 01 finishes" and
"next Tuesday" are not. Workspaces exist per **in-flight judgment stream**; work
that runs agent-to-end and needs only a transactional approve/reject at a gate
is subagent fan-out inside an existing workspace.

## 4. Waves

| Wave | Action | Who |
|---|---|---|
| 0 | Commit this plan + `lanes.json` + every `lanes/NN-*.md`. | orchestrator |
| 1 | Open workspaces for lanes <NN, NN>; paste the four-line pointer each; grant/withhold <A1, A2> by editing each brief's §4. | approver |
| 2 | Build to committed handoffs with evidence. | lanes |
| 3 | Open the review lane against stable pushed tips, with profile §5 as its lens list. | orchestrator |
| 4 | Triage findings; lanes repair in place and re-push. | orchestrator + lanes |
| 5 | Re-review at the assembled candidate, rerunning the original probes. | reviewer |
| 6 | Merge in §7 order, resolve shared files once, one PR to the default branch, babysit the automatic checks. | orchestrator |
| 7 | Post-merge release gates: <A3, T2…> in order, each a thin PR. | approver + lanes |
| 8 | Verify every lane branch is an ancestor of the default branch; write `CLOSEOUT.md`; name the workspaces safe to archive. | orchestrator |

## 5. Approvals the approver controls

Each is granted separately by editing the named lane brief's §4 before pasting.
**No approval implies the next one. No step inherits authorization from the
previous step.** The action surface is profile §4.

1. **A1 — <exact bounded action>** (lane <NN>). Authorizes: <exactly what, to
   exactly which target>. Does **not** authorize: any other rung on the profile
   §2 ladder, any other action on the profile §4 list, or any other lane's
   equivalent action.
2. **A2 — <…>** (lane <NN>). Authorizes: <…>. Does **not** authorize: <…>.
3. **T1 — <ratification touchpoint>** (lane <NN>, synchronous, mid-build).
   Ratifies: <the exact bytes / pinned values>. Does **not** authorize any write.
4. **A3 — <the irreversible rung from profile §2>** (after <gate>). Separate from
   A1 and separate again from everything downstream of it.

**Each profile §4 action:** <requested by lane NN under A<n> | not requested
anywhere in this program — refuse>.

## 6. Explicitly out of scope — do not start in any lane

- <named follow-on work>, <named refactor>, <named migration>.
- No new services or pipelines, no scheduler or deployment changes, no
  shared-framework extraction, and no change to a frozen contract, unless a
  numbered approval above names it.
- None of the above may start from this program's authority even if a lane
  finishes early. Escalate instead.

## 7. Integration order

`<lane NN>` → `<lane NN>` → `<lane NN>` → orchestrator-owned shared files.

The shared aggregators in profile §3 are resolved **exactly once**, centrally,
from the shared-file requests in each handoff. Lanes never edit them, except for
any file §3 declares a mandated exception. Known-nasty merges and their
resolutions are listed there too — follow them rather than hand-merging.

## 8. Definition of done for the program

1. Every lane has a committed handoff with a **SAFE TO INTEGRATE** verdict.
2. The reviewer's findings are each verdicted CLOSED at a re-reviewed candidate,
   with the original probes rerun — not the repair diffs read.
3. `<the program's acceptance gate command(s), from profile §1>` pass on the
   merge candidate.
4. Post-merge checks are green and every lane branch is an ancestor of the
   default branch.
5. Each remaining release flag is either flipped under its own numbered approval
   or explicitly recorded in `CLOSEOUT.md` as an approval the human still owns.
6. `CLOSEOUT.md` exists, with the profile §2 ladder matrix filled per lane.
