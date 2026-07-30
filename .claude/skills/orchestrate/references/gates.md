# Gates

Everything here is structure. The concrete commands, rungs, and irreversible
actions live in **`orchestration/PROFILE.md`** — read it first, and let it win.

## The ladder — "done" is not binary

Decompose "done" into separately-approved states, and make every status surface
distinguish them. Blurring rungs is how a changelog ends up claiming something is
released when it is sitting one merge short.

The repo's rungs are **profile §2**. A typical shape:

```
source-complete → built → gates-green → deployed-somewhere-safe
  → reviewed → merged → released   ← the irreversible one
```

Report it as a matrix, lanes across the top, plus a plain flag vector:

```
- <gate>: <result>
- <gate>: <result>
- merged: false
- released: false        ← mark the point of no return explicitly
```

**Name the point of no return in every status report.** A rung that was cheap
last month may not be cheap today — one profile described its release step as a
deploy to a private staging host, which had silently become publication to a
live, indexed site. The command was identical; the blast radius was not.

## Approval tokens

Name them (A1, A2… for authority grants; T1, T2… for judgment touchpoints the
approver owns). Put them in the lane brief as an editable block the approver
fills in **before dispatch**, and enumerate the **non-grants** explicitly.

Three rules:

1. **Nothing inherits.** No step inherits authorization from the previous step. A
   green gate does not authorize a merge; a merge does not authorize a release.
2. **Approval binds to exact bytes.** Bind it to a hash of the thing approved, so
   an edit after approval invalidates it rather than riding along.
3. **No code path may synthesize an approval.** Tooling should be able to
   *record* a human decision and never to *manufacture* one. If a script can
   write the approved state from its own output, the approval is decorative.

Schedule judgment touchpoints up front. A lane that discovers it needs the
approver at the end has mis-planned.

## Executable gates

A gate is a **command**, not a paragraph. Every lane has exactly one acceptance
command in `lanes.json`, taken from profile §1.

Two failure modes, both observed:

- **The gate was decorative.** A builder wrote its own validator and it checked
  almost nothing — a run of twenty zeroes could be made to pass by inflating one
  item's score. → **The lane never authors its own gate.** Gate authorship is an
  ownership boundary, exactly like write-scope.
- **The gate was never invoked.** The validator was correct and CI simply didn't
  call it on the default path. → **Wire it into the default path**, ahead of
  anything that could cause a skip (credential setup, conditional steps). If the
  repo has no CI, profile §1 must say so, and the orchestrator runs the gates on
  the assembled candidate itself.

Underneath both: **recompute, never trust.** A recorded "passed" boolean is an
assertion. Validators should recompute from evidence and treat a missing field as
failure, not default-pass.

**Write negative tests.** A gate with no test proving it *rejects* is untested.
Prove rejection: stale inputs, missing fields, a zero score, a duplicate
identity, a self-certifying grader, a one-byte drift in a frozen artifact.

## Certification gates

Only when a lane ships something **judged** rather than tested — a semantic
surface, a generated artifact, a model output. Skip otherwise.

**Separate the two artifacts.** The builder's harness produces an **ungraded
result bundle**; an independent grader produces the **graded record**. The bundle
should say so in its own README: it contains no scores and no pass/fail
determination, because those belong to the reviewer.

**Grader ≠ producer, enforced in code.** The grader identity must be non-empty
and distinct from the producer identity. A string check is necessary and not
sufficient — the orchestrator must also *operationally* ensure independence.
Different model families beats different sessions.

**Hard gates** are booleans that must be present, explicitly false, and
independently recomputed. A missing gate field is a mechanical failure.

**Include cases that must be refused.** Honest refusal is a first-class correct
answer, and a surface that never refuses will confabulate.

**Ablations cannot qualify.** Only the full governed condition opens a gate.

## Artifact-digest binding

When something gets certified, bind the certification to the **bytes evaluated**,
not to the commit.

> A run qualifies iff the current checkout's evaluated artifacts are
> digest-identical to the digests pinned in the run record. The repository SHA is
> **provenance only**. Any single-byte change to an evaluated artifact
> immediately de-qualifies the run.

It solves two opposite problems. Too loose: a certification passes, someone edits
a definition, and the result is silently inherited by different behavior. Too
tight: whole-repo SHA equality means a README typo breaks qualification, which
pressures people to fake it.

Digest over `(name || NUL || bytes || NUL)` per file in a declared order.
Recompute from the checkout; never trust a recorded staleness flag.

**Sequence certification last in a lane and freeze the artifacts before pinning.**
Every artifact touch after pinning forces a re-pin. That cost is the gate working,
but it is avoidable cost.

## Evidence — what counts as proof

- The exact command **and its verbatim output**
- `file:line` citations
- Counts, not adjectives: `878 passed`, `157 passed, 0 failed`
- Results from the real system, pasted as fenced blocks, with the target named
- Boundary probes (input → computed → result), not just the happy path
- Negative tests proving the gate rejects
- A clean `git diff --check`, and the branch pushed

## Retention

**Never delete failed or excluded evidence.** One certification run was discarded
because the harness had leaked a repo file into the evaluated context — kept,
with its reason, rather than deleted, even though forensics found no actual
access to the answers. Superseded records are marked historical and
non-qualifying, not rewritten.

Deleting the evidence of a near-miss is how you relearn it.
