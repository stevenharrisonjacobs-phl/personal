---
name: orchestrate
description: Run a large or irreversible effort as an orchestrator/worker program in any repo — frozen contracts, path-scoped lanes, non-transitive approvals, independent adversarial review, central integration. Reads a per-repo orchestration/PROFILE.md for gates, ladder, and irreversible actions. Use when Steven says "orchestrate this", "split this across workspaces", "run this as a program", "write worker prompts", "set up lanes", or when a task is too large, too parallel, or too irreversible for one session.
---

# Orchestrate a multi-lane program

The heavyweight instrument. Distilled from two programs that ran end to end on a
real codebase — including their failures, which are why most of the rules below
exist. Don't dilute it for small work; for small work, just do the work.

**This skill is half the picture.** It supplies the structure: the loop, the
invariants, the artifacts, the scripts. The repo supplies the rest.

## First: find the profile

```bash
cat orchestration/PROFILE.md
```

`orchestration/PROFILE.md` holds the six things that differ in every repo —
**gate commands, the ladder, shared aggregators, irreversible actions, review
lenses, frozen contracts.** Where it disagrees with anything in this skill, **the
profile wins.**

**No profile?** This repo hasn't adopted the harness. Say so, then offer to
create one:

```bash
bash .claude/skills/orchestrate/scripts/orch-adopt.sh
```

That scaffolds `orchestration/PROFILE.md` from the template and probes the repo
for starting answers. **Do not run a program without one** — a program whose
gates and irreversible actions are undefined is exactly the situation this skill
exists to prevent. Filling the profile is a conversation with the approver, not a
guess: it names what can't be undone.

**Profile older than a few days?** Re-verify before relying on it. A stale gate
command or a "safe" action that quietly became irreversible is worse than no
profile — that failure has already happened once, and it told operators an
irreversible action was cheap when it had become publication to a live system.

## The loop

```
ORCHESTRATOR                                      LANE (worker)
  read the profile; scope + freeze contracts
  split into lanes ────────────────────────────▶  ground (read list)
  write orchestration/<program>/lanes/NN-*.md     plan → STOP for the approver
  hand the approver a 4-line pointer per lane     build
                                                  completion loop until evidence
  verify from git + the real system,  ◀────────── committed HANDOFF + verdict
    never from claims
  independent review (orchestrator fan-out)
  integrate centrally, run the gates
  closeout
```

## Decide the shape before writing anything

**Is this a program at all?** Yes if two or more of: it needs more than one
judgment stream; it touches something on the profile's irreversible list; it
spans more than a day; more than one lane would edit the same shared file.

**How many workspaces?** One per **in-flight judgment stream** — a lane that will
need the approver's call *during* the build. Work that runs agent-to-end and
needs only a transactional approve/reject at the end is **subagent fan-out inside
an existing workspace**. Count judgment streams, not tasks.

**Where does the reviewer go?** It needs *independence*, not judgment: fresh
context, a prompt it did not write, and nothing but git and the real system to
look at. A subagent **of the orchestrator** satisfies that. It may never be a
subagent of the lane it reviews.

**Program or standing?** A program has waves and a closeout. A standing effort
accumulates `decisions/` forever and must stay findable — set `standing: true`
and keep `orchestration/CURRENT.md` pointing at the live orchestrator branch.

## The seven invariants

Structure, not policy. Each is here because its absence cost something real.

1. **Freeze an interface, then parallelize.** A pinned, source-controlled
   contract is what converts a serial dependency into concurrent lanes.
   Consumers build against it *immediately*. A contract change is an escalation
   the orchestrator fans out, never a reason for a lane to idle. → profile §6.

2. **One writer per path-scope.** Every lane declares owned globs and an explicit
   forbid list. Shared aggregators belong to the orchestrator and are resolved
   **exactly once**, centrally. Lanes request shared edits in their handoff.
   → profile §3.

3. **Nothing inherits authority.** Every action on the profile's irreversible
   list needs its own named, separately granted approval, pasted as an editable
   block in the lane brief with the non-grants enumerated. Approval binds to
   exact bytes, and **no code path may synthesize one.** → profile §4.

4. **A lane cannot certify itself — and cannot author its own gate.** A reviewer
   once caught a lane grading its own work; a spot-check of 4 of 15 items found
   the self-assessment inflated. Worse, a builder-authored validator turned out
   decorative — a run of twenty zeroes could still pass by inflating one item's
   score. **The orchestrator or the reviewer authors the gate.** → profile §1.

5. **A gate not wired into the default path is not a gate.** One correct
   validator existed and was simply never invoked by CI. If the repo has no CI,
   say so in the profile and accept the consequence: **the orchestrator is the
   CI**, and runs the gates on the assembled candidate itself.

6. **Verify against reality, and from git — never from claims.** Unit tests pass
   while real execution fails. The orchestrator's pattern: fetch branch → scope
   audit against owned globs → clean-worktree gate run → live spot-checks.
   Recorded booleans are assertions; recompute them.

7. **Assume the worktree dies.** The bus lives in committed `orchestration/`,
   never gitignored scratch — a ratified decision once nearly died that way.
   Cross-workspace references use repo paths and branch/PR numbers, never
   `../../../<workspace>/`, which breaks the moment a worktree is archived.

## The bus — `orchestration/`

```
orchestration/
  PROFILE.md                       # the repo half: gates, ladder, aggregators,
                                   #   irreversibles, lenses, contracts
  CURRENT.md                       # active programs + their orchestrator branches
  <program>/
    PLAN.md                        # prose: goal, frozen contracts, waves, approvals
    lanes.json                     # machine-readable lane registry (scripts read this)
    lanes/NN-<lane>.md             # the worker brief — pointer-pasted, not pasted
    escalations/ESCALATION-<date>-<topic>.md
    decisions/DECISION-<date>-<topic>.md
    STATUS.md                      # orchestrator-maintained ladder state
```

Dispatch is four lines, not a hundred and fifty:

```
You are the worker for lane 02 of program <X> in <repo>.
git fetch origin && git checkout -b <branch> origin/<default>
Read orchestration/<X>/lanes/02-<lane>.md and follow it exactly.
Granted approvals: A1 only. No others.
```

A pasted prompt goes stale the moment the orchestrator revises it. A pointer
never does.

## Ceremonies, and what switches them on

| Ceremony | Switches on when | Reference |
|---|---|---|
| Approval tokens (A1, A2…) | the program touches anything on profile §4 | `references/gates.md` |
| Independent adversarial review | more than one lane, or anything irreversible | `references/reviewer.md` |
| Certification gate | a lane ships something judged rather than tested | `references/gates.md` |
| Escalation → decision record | a lane wants to cross an ownership boundary | `references/escalation.md` |
| Ladder state in every status | anything can be "done" at more than one level | `references/gates.md` |

## Run it

**Adopt in a new repo** — `bash .claude/skills/orchestrate/scripts/orch-adopt.sh`,
then fill `orchestration/PROFILE.md` **by measuring**, and commit it.

**Start a program** — read `references/orchestrator.md`, then:

```bash
bash .claude/skills/orchestrate/scripts/orch-init.sh <program-slug>
```

Fill `PLAN.md` and `lanes.json`, write each `lanes/NN-*.md` from
`templates/LANE.md`, then hand the approver the four-line pointer per lane.

**Work a lane** — `references/worker.md`. **Review** — `references/reviewer.md`.

**Check on it:**

```bash
bash .claude/skills/orchestrate/scripts/orch-status.sh <program-slug>
bash .claude/skills/orchestrate/scripts/orch-scope-audit.sh <program-slug> [lane-id]
```

**Close out** — write `CLOSEOUT.md`, verify every lane branch is an ancestor of
the default branch, then run `/archive` per workspace. **Archival is not a
substitute for merging.** If the profile names a release step beyond merge, that
is its own separately approved action — this skill never takes it.
