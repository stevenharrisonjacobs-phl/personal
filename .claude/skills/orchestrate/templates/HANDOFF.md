<!-- Handoff template. The LANE writes this at the end of its completion loop and
     commits it on its own branch as docs/HANDOFF-<date>-<lane>.md. It is the
     only thing the orchestrator is contractually owed — and the orchestrator
     will still verify every claim in it from git, not from the claim.

     Section order is fixed. Do not reorder, do not drop a section: write
     "none" under one that does not apply. Every number and status here must be
     a value you actually observed this session; do not carry one forward from a
     previous handoff. Status vocabulary comes from orchestration/PROFILE.md §2 —
     never from words like "done" or "shipped". -->

# Handoff — <lane name>

Date: <YYYY-MM-DD> · Program: `<program-slug>` · Lane: <NN>

## Workspace and revision

- Workspace: `<absolute workspace path>`
- Branch: `<branch>`
- HEAD: `<40-char sha>`
- Base lineage: `origin/<default-branch>` at `<sha>`
- Push confirmation: **yes | no**. <State exactly what the remote contains. If
  this handoff commit itself lands after the push, say so and name the tip the
  delivery response will report.>

## Outcome and owned changes

<One sentence naming the rung this lane's surface now stands on, in profile §2's
exact vocabulary, and every later rung it explicitly has NOT reached — e.g.
"<rung 2> and <rung 3>; not <rung 4>, <rung 5>, or <the irreversible rung>.">

The change:

- <owned change, one bullet each — what it now does, not how you felt about it>
- <…>

<Any file you expected to consume and did not find, or any shape you had to
assume because a shared artifact had not landed yet. Say it plainly here.>

## External actions and authority

<Name each action from profile §4 you performed and the approval that authorized
it. If none occurred, say so plainly and completely.>

- <action> — authorized by **A<n>** (<the exact grant text>).
- No <the remaining profile §4 actions, enumerated> occurred.

The only operations against live systems were <read-only inspections / dry runs>.
<Any prior approval remains unchanged; it did not authorize any new write here.>

## Gate and real checks

<Exact commands and verbatim results with counts. Recorded booleans are
assertions — these must be things you ran this session.>

- Acceptance gate `<exact command from the brief §8>`: **<verbatim result>**.
- `<exact command>`: **<N> passed**.
- `<exact command>`: `<verbatim output line>`.
- Negative tests reject: <case>; <case>; <case>.
- Read-only spot-checks against the live system: <what was probed, and the exact
  counts returned>.
- `git diff --check origin/<default-branch>...<sha>`: <clean | the exact complaint>.

## Current ladder position

One line per rung in `orchestration/PROFILE.md` §2, with the value you observed —
the profile's rung names verbatim, no substitutes.

- `<rung 1>`: <value>
- `<rung 2>`: <value>
- `<rung 3>`: <value>
- `<the irreversible rung>`: false

## Unresolved decisions and known risks

- <the decision you could not make and who owns it>
- <risk, and the concrete thing that would make it real>
- <anything you deliberately deferred, and why>

## Shared-file requests and exact next dependency

Orchestrator:

1. <profile §3 shared-file change requested, with the exact edit — you did not
   make it>
2. <reconciliation needed against another lane's artifact>
3. <gate or automation wiring you cannot do from this lane>

The exact next dependency is <the one artifact or event that must exist before
this lane's work advances>. <State plainly what must NOT be done on this branch.>

## Downstream design observations

<Anything learned here that changes the design of planned downstream work.
Grain, cardinality, an inverted assumption you verified against the live system,
a source wart. If nothing changed, say the earlier observations are unchanged
and restate them in one line.>

## Integration recommendation

**SAFE TO INTEGRATE | NOT SAFE TO INTEGRATE** as <the exact scope of the claim>.

This recommendation certifies <exactly what> only. It does **not** claim
<the qualification or certification you did not earn> and does **not** authorize
any rung of the profile §2 ladder beyond the one named above, any action on the
profile §4 list, any downstream compatibility flip, or any approval not already
granted in this lane's §4.
