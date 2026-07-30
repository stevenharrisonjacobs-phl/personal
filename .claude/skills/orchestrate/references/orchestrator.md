# Orchestrator

You own the program: dependency ownership, shared files, and integration. **You
are not a substitute for a domain worker.** If you find yourself implementing a
lane's work, you have either mis-split the program or absorbed a lane you should
have dispatched.

Read `orchestration/PROFILE.md` first. It supplies the six repo-specific inputs
this document assumes — gate commands (§1), the ladder (§2), shared aggregators
(§3), irreversible and external actions (§4), review lenses (§5), frozen
contracts (§6) — and **where it and this file disagree, it wins**. If the repo has
no profile, write one before dispatching: without it every lane invents its own
version of all six.

## 1. Scope and freeze, before anything else

Write `orchestration/<program>/PLAN.md` from `templates/PLAN.md`. The part that
matters most is the **frozen contracts** table — start from profile §6, and for
each shared interface record the artifact path, its owner, its consumers, and the
SHA it froze at.

A frozen contract is what converts a serial dependency into concurrent lanes.
Consumers implement against it *immediately* — "not audit-only". Say so in their
briefs, and enumerate what genuinely stays blocked (usually only: integrated
real-data checks, compatibility-flag flips, and final certification).

If a contract must change mid-program, that is **your** event: you ratify the
change, fan it out to every consumer lane, and re-pin. It is never a reason for a
lane to idle.

> **Freeze the shared protocol before you freeze the domain contract.** The most
> expensive rework on record was two entire follow-on programs whose only purpose
> was retrofitting already-shipped lanes onto a shared contract that got ratified
> *after* they shipped. If a shared contract is still in motion and you cannot
> wait, say so in the brief and budget the retrofit as its own lane. Do not let a
> lane discover it.

## 2. Split into lanes

A lane is a **path-scope** and a **judgment stream** at the same time. Both must
hold, or the split is wrong.

- One **workspace** per in-flight judgment stream — a lane that will need the
  approver's ratification, a meaning call, or a risk decision *during* the build.
- Everything agent-to-end with only a transactional approve/reject at a gate is
  **subagent fan-out**, inside a workspace that already exists.
- Give every lane a **phase split** so a blocked lane still has work: Phase A
  needs nothing; Phase B unblocks on an artifact condition the lane can check
  itself (a read-only inspection of the live system, a branch existing on origin);
  Phase C is post-approval and must not start without explicit instruction.
- **Start conditions are artifact conditions, never calendar ones.** "After lane
  01's contract is frozen (*not* full certification)" — partial unblocks are the
  point.

Record all of it in `lanes.json`. That file is what the scripts read; `PLAN.md` is
the prose for humans. The profile's optional "Lane boundaries" section, if the
repo filled it in, is where to look for natural disjoint path-scopes before
inventing your own.

### When the two cuts disagree

They will. Work that has **one judgment stream but no disjoint write-scope** — a
repo-wide rename, a cross-cutting convention change, a repo-wide reformat — is
**never a parallel lane.** It is a wave of its own, before or after the lanes, or
it is subagent fan-out inside the orchestrator. Trying to run it beside the lanes
guarantees the merge you designed the split to avoid.

The converse also holds: disjoint globs with **no** independent judgment stream is
fan-out, not a lane. Do not spend a workspace on it.

### Sizing a lane

"One writer per path-scope" says nothing about whether that scope fits in one
agent's head. A clean glob can still be a terrible lane. Split when any of these
is true:

- The lane cannot state its own acceptance evidence in about a page.
- It has to hold two unrelated subsystems in context simultaneously.
- Its owned globs run to dozens of files it must actually reason about (a
  directory of near-identical primitives does not count).

### Lane count has a ceiling, and it is not parallelism

Judgment streams set the **lower** bound on how many lanes you need. They are also
the **upper** bound: every lane is a conversation the human approver has to hold,
and their attention is the scarce resource, not compute. Three or four concurrent
lanes is usually the real ceiling regardless of how cleanly the paths divide. If
the split wants more, merge lanes that share a decision, or run a second wave.

### The split is static

It is decided once, up front. The Phase A/B/C split is the only concession to
discovering you were wrong. A program that turns out to have a different shape
mid-flight escalates and is re-planned centrally — lanes never re-split
themselves. That is the right trade for irreversible work and the wrong one for
exploratory work: if you do not yet know what you are building, do not reach for
this skill.

## 3. Author the gates

**You author every lane's acceptance gate. The lane never does.**

One program's independent review found a builder-authored validator that was
purely decorative — *"A run with twenty zeroes can be made qualifying by inflating
another question's score or `max_score`"* (F4). A lane that writes its own gate
writes a gate it can pass.

Each lane's `gate` field in `lanes.json` is an exact command, taken from or
composed out of profile §1. Wire it into whatever the repo runs automatically
(profile §1, "what runs automatically") on the **default path**, before credential
materialization, so it cannot be skipped for lack of access — that was F1's real
failure, a correct validator that the automated path never invoked. If the
profile's honest answer is "nothing runs automatically", then **you** are the CI:
run every gate yourself at each verify step, and say so in the plan.

Respect profile §1's known-bad baselines. Gating a lane on debt it did not create
teaches lanes to argue with gates.

See `gates.md` for approval tokens, evidence standards, and certification
mechanics; see profile §2 for this repo's ladder.

## 4. Dispatch

Write each `orchestration/<program>/lanes/NN-<lane>.md` from `templates/LANE.md`.
**Commit them.** Then give the approver the pointer per lane:

```
You are the worker for lane 02 of program <X> in <repo>.
git fetch origin && git checkout -b <branch> origin/<default-branch>
Read orchestration/<X>/lanes/02-<lane>.md and follow it exactly.
Granted approvals: A1 only. No others.
```

The approver grants or withholds approvals by editing §4 of the lane file before
sending the pointer. That is the human-authority insertion point — keep it there
and keep it explicit.

## 5. Verify — from git, never from claims

The standing pattern:

> fetch branch → **scope audit against owned globs** → clean-worktree gate
> commands from profile §1 → permitted read-only checks against the live system

```bash
bash ~/.claude/skills/orchestrate/scripts/orch-status.sh <program>
bash ~/.claude/skills/orchestrate/scripts/orch-scope-audit.sh <program>
```

Reject incomplete lanes back into their loops. A handoff that claims a check
passed is not the check passing — re-run it. (One reviewer re-ran
`git diff --check` on a lane that reported it clean and found trailing whitespace
in the handoff itself.)

Recorded booleans are assertions. Recompute them.

## 6. Review before integrating

Spawn the independent reviewer — see `reviewer.md`, and hand it profile §5 as its
lens list. It is a subagent **of yours**, with fresh context and a prompt it did
not write. It may not be a subagent of any lane it reviews.

Triage findings, bounce the affected lanes, and require **re-review at new pushed
tips** by rerunning the original probes, not by reading the repair diffs.

## 7. Integrate — centrally, exactly once

1. Fetch all lane branches; verify clean pushed tips and complete handoffs.
2. Create an integration branch; merge **in dependency order**.
3. Resolve every shared aggregator (profile §3) **exactly once**, here. This is
   why lanes are forbidden from touching them — the busiest aggregator in one
   program was edited 10–13 times a day and never once conflicted.
4. Apply requested flag flips **only** where handoff evidence supports them.
   Never speculatively.
5. Full gate sweep from profile §1 on the assembled candidate.
6. Permitted read-only checks against the live system, including fail-closed
   probes.
7. Update the shared aggregators under §3's stated discipline, and the program's
   status doc.
8. **One** PR to the default branch. Babysit whatever runs on it. Merge with a
   merge commit.
9. Verify post-merge checks, and that every lane branch is an ancestor of the
   default branch. Report which workspaces are safe to archive.
10. Track remaining milestones in the profile §2 ladder's vocabulary — never in
    ad-hoc words like "done" or "shipped".

**Archival is not a substitute for merging.**

## 8. Close out

Write `CLOSEOUT.md` from `templates/CLOSEOUT.md`. Amend it **in place** with a terminal
marker (`# PROGRAM COMPLETE — <date>`) rather than replacing it. Tell each
workspace to run `/archive`.

If the program is **standing** (`"standing": true`), there is no closeout. Instead:
keep `orchestration/CURRENT.md` pointing at your live orchestrator branch, and let
`decisions/` accumulate. A standing orchestrator that cannot be located is worse
than none — two workspaces once held byte-identical decision directories with
nothing on disk saying which was authoritative.
