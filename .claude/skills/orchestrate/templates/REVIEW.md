<!-- Independent review template. Written by the REVIEWER — a subagent of the
     orchestrator, or its own workspace if adjudicating findings will need the
     approver mid-review. Never a subagent of a lane it reviews, and never the
     lane that authored the gate it is checking.

     Commit at docs/<PROGRAM>-INTEGRATION-REVIEW-<date>.md. The re-review is
     APPENDED to this same file — a second document loses the finding lineage.
     Read only git, the frozen contracts, and orchestration/PROFILE.md; §5 is
     your lens list. Verify against reality: recompute every recorded boolean;
     a passing unit test is not a passing system. -->

# <Program> integration review

Date: <YYYY-MM-DD> · Reviewer branch: `<branch>`

Base: `origin/<default-branch>` at `<40-char sha>`

Reviewed tips:

- <lane>: `<branch>` at `<40-char sha>`
- <lane>: `<branch>` at `<40-char sha>`

## Executive verdict

**SAFE TO INTEGRATE | NOT SAFE TO INTEGRATE <which tips> as submitted.**

<One paragraph: what is substantially correct, then the exact count and shape of
what blocks — "blocked by one release-gate contradiction and N major defects" —
then a numbered one-line list of those defects. Then one paragraph on what must
stay `false` / unflipped regardless of repair.>

## What is correct

Stated first, deliberately. <Bullet the load-bearing things you examined and
found sound — the grains, the scopes, the guards, the fail-closed defaults. A
reviewer who lists only defects gives the orchestrator no way to tell "examined
and clean" from "not examined".>

- <claim verified, with the evidence that verified it>

## Findings

### F<n> — <blocker | major | minor> — <one-line defect statement>

**Evidence**

- `<branch>:<path>:<line>` <what it says, quoted or paraphrased exactly>
- Exact-tip reproduction:

  ```text
  <exact command>

  <verbatim output>
  ```

**Affected paths**

- `<path>`
- `<path>`

**Acceptance check** (numbered, falsifiable — each must be a thing that can be
run and observed, not a thing that can be asserted)

1. <check>
2. <check that specifically closes the escape, not the symptom>
3. On the repaired tip, `<exact command>` must return `<exact value>`.

**Failure mode:** <what actually goes wrong in production if this ships — the
silent-corruption path, not the test that goes red>.

**Routed to:** lane <NN> | orchestrator <, with <who> owning <the shared part>>.

## Checks that passed

Everything below was examined and found clean. **Absence of a finding above is
affirmative evidence, not an unexamined gap.**

- Full exact-tip gate runs (profile §1): <lane>: **<N> passed**; <lane>:
  **<N> passed**.
- <validator/gate command>: `<verbatim status>`. Live <artifact> vs frozen
  contract: <exact match detail>.
- <adversarial probe class>: all <N> probes rejected. <perimeter / guard /
  fail-closed default>: verified.
- No reviewed branch performed any action on the profile §4 list, and this
  review performed none.

## Per-branch integration verdict

| Branch | Verdict | Reason |
|---|---|---|
| `<branch>` | **SAFE / NOT SAFE TO INTEGRATE** | <one sentence, naming the finding ids> |

<One line on repair order: repaired in place, re-reviewed at new pushed tips,
then merged in <order>. Name every flag that must not change during repair.>

---

## Re-review — assembled integration candidate

Re-review date: <YYYY-MM-DD>

Candidate: `<branch>` at `<40-char sha>`

Confirmed included repair tips: <lane>: `<sha>`; <lane>: `<sha>`.

### Re-review verdict

**SAFE TO INTEGRATE `<branch>` at `<sha>` as <the exact scope of the claim>.**

<What is closed and at what level — "at the mechanism/source level" is a
different claim from "qualified". Name what this verdict does NOT authorize, in
profile §2 and §4 vocabulary.>

This re-review used a **detached exact-tip worktree and reran the original
adversarial probes** rather than relying on the repair diffs. A diff that looks
correct is not evidence that the escape is closed.

### F<n> — <severity> — CLOSED | OPEN | CLOSED WITH RESIDUE

**Concrete evidence**

- `<path>:<lines>` <what now holds>
- `<exact command>` → `<verbatim output>`

<If CLOSED WITH RESIDUE: name the residue and the separate gate that owns it.>

### Combined validation summary

- Full integration-candidate gate sweep: **<N> passed, <N> skipped** <and how any
  skip was separately satisfied>.
- Focused <gate> tests: **<N> passed**.
- `git diff --check origin/<default-branch>...<sha>`: clean.
- Read-only inspection only; this re-review performed no action on the profile
  §4 list.

### Final per-finding verdict

| Finding | Original severity | Re-review verdict |
|---|---|---|
| F1 — <short name> | blocker | **CLOSED** |
| F2 — <short name> | major | **CLOSED** |

Overall: **<verdict>; not authorized for <the enumerated list of things this
does not grant> until the separately governed gates pass.**
