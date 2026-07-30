<!-- Closeout template. Written by the ORCHESTRATOR and shipped with the final
     integration PR, at docs/<PROGRAM>-CLOSEOUT-<date>.md. This is the program's
     terminal record: the one document a cold reader opens in six months.

     It is AMENDED IN PLACE, never replaced. When the last release gate closes,
     append the `# PROGRAM COMPLETE — <date>` marker at the bottom with the final
     matrix — do not rewrite the body above it. The body records what the
     integration PR shipped; the marker records that the program ended. Both are
     true, at different times, and the sequence is the point.

     Rung names come from orchestration/PROFILE.md §2, verbatim. Do not write this
     until every lane branch is verified an ancestor of the default branch.
     Archival is not a substitute for merging. -->

# <Program> closeout — <YYYY-MM-DD>

**Program:** `<program-slug>` · **Orchestrator branch:** `<branch>`
Candidate certified by independent re-review at `<sha>`; this document ships
with the final integration PR.
Plan of record: `orchestration/<program-slug>/PLAN.md`.
Profile of record: `orchestration/PROFILE.md`, last verified `<YYYY-MM-DD>`.

## Ladder

Rungs from profile §2, in order, lanes across the top.

| Rung | <lane 01> | <lane 02> | <lane 03> |
|---|---|---|---|
| `<rung 1>` | yes | yes | yes |
| `<rung 2>` | yes | <candidate (isolated)> | yes |
| `<rung 3>` | yes | <yes (N/N parity)> | <yes (incl. <the live check>)> |
| `<rung 4>` | <yes — N/N qualifying> | <pending (<gate>)> | <pending> |
| `<rung 5>` | no | <…> | no |
| `<the irreversible rung>` | no | no | no |

Every lane remains fail-closed to ordinary use. <This PR is a source +
development-certification milestone; it grants no rung beyond `<rung N>`.>

## What shipped, per lane

| Lane / branch | PR | Outcome |
|---|---|---|
| <lane 01> `<branch>` | #<n> | <what landed, in ladder vocabulary> |
| <lane 02> `<branch>` | #<n> | <…> |
| <reviewer> `<branch>` | #<n> | Independent adversarial review: <N> blocker + <N> major + <N> minor found, all verified CLOSED on the assembled candidate |
| Orchestrator | #<n> | <shared-file resolutions, gate/automation wiring, cross-lane reconciliations, doc/status corrections> |

Release flags after the final PR:

- <lane/domain>: `<flag>: <value>`, `<flag>: <value>`.
- <lane/domain>: `<flag>: <value>`.

## Decisions ratified through this program

1. **<decision>** — `<path to DECISION file>`. <One line: what it fixed.>
2. **<decision>** — <one line>.
3. <Any decision made inline during integration that has no DECISION file —
   record it HERE, because this is now its only home.>

## Where everything lives

All committed; nothing load-bearing sits in an ignored scratch directory.

- Plan, lane briefs, escalations, decisions: `orchestration/<program-slug>/`
- Repo profile: `orchestration/PROFILE.md`
- Handoffs: `docs/HANDOFF-<date>-<lane>.md` (one per lane)
- Review + re-review (one document, appended): `docs/<PROGRAM>-INTEGRATION-REVIEW-<date>.md`
- Runtime / contract / gate: `<paths>`
- Certification evidence and qualifying runs: `<paths>`
- Runbooks: `<paths>`

## Remaining approvals the human still owns

Each separate; **none inherited**. Each is an entry in profile §4 or a rung of
profile §2.

1. **<A<n>> — <exact action>**: <what it authorizes, and the runbook that
   governs it>.
2. **<gate>**: <the condition that must hold first>.
3. **<the irreversible rung>**: last, separately, per lane.

## How to resume / next program

<What a cold reader does first: which doc holds current state, which docs are
now stale and must not be trusted for it.>

The follow-on is <program name>, packeted at `<path>`. <What it depends on from
this program, and the explicit statement that none of it may start from this
program's authority.>

## Workspace archival

Every lane branch was verified an ancestor of the default branch at `<sha>`. The
following workspaces are safe to archive with `/archive`: <list>.
**Archival is not a substitute for merging.**

---

<!-- Append the block below IN PLACE when the last gate closes. Do not replace
     the body above it. -->

# PROGRAM COMPLETE — <YYYY-MM-DD>

Every release milestone in this document is done. Final state:

| <Lane/domain> | Ratified | `<rung>` | `<rung>` | `<rung>` | `<the irreversible rung>` |
|---|---|---|---|---|---|
| <name> | <date> | <target> | <N/N (<run id>)> | <cadence> | **<date>** |
| <name> | <date> | <target> | <N/N (<run id>)> | <cadence> | **<date>** |

<Any narrow, exactly-scoped exception granted at the final transition — what it
permits, that it is fail-closed for everything else, and that it has tests.>

Follow-on: <next program> (`<path>`) and <the standing work that continues>.
