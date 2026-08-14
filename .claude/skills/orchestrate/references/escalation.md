# Escalation → decision

The rule that makes parallel lanes safe: **escalate, never edit, across an
ownership boundary.** A lane that quietly fixes a shared contract has silently
forked it for every other lane, and nobody finds out until integration.

## When a lane escalates

- It wants to change anything outside its owned globs — a frozen contract
  (profile §6), a shared aggregator (profile §3), another lane's paths.
- It wants an action on the irreversible list (profile §4) that its brief's §4
  does not grant.
- The business meaning, ground truth, or intended scope is genuinely ambiguous.
- It is an acceptable-risk call.
- It found something that **breaks** a frozen contract — the highest-priority
  escalation, because every consumer lane is now building against a false premise.

**Do not escalate anything answerable from the repo, a read-only check, or a
test.** Go find out. An escalation that a five-minute probe would have answered
costs the orchestrator's attention and teaches lanes that escalating is cheaper
than working.

## Format

> **State the evidence, recommend ONE direction, and give the smallest concrete
> set of alternatives with their consequences.**

Write it to `orchestration/<program>/escalations/ESCALATION-<date>-<topic>.md`
from `templates/ESCALATION.md`, commit it on the lane's branch, and say it exists.
Then **continue on whatever is not blocked** while you wait.

Be explicit about disposition — what you have and have not done, and that you are
ready to build whatever gets ratified, on the orchestrator's timeline. The best
one in the source corpus ended: *"Escalating only. No contract edit, no new
writer, no policy draft from this workspace."*

## When the orchestrator decides

Write `orchestration/<program>/decisions/DECISION-<date>-<topic>.md` from
`templates/DECISION.md`. Four things make a decision doc worth writing:

**1. A ruling table first.** Question | Ruling. Someone should read six rows and
stop.

**2. Reasoning that can overturn the framing.** Read the escalation's premise as
a hypothesis, not a given. One real ruling rejected the escalation's own framing:
the escalation called a field "the riskiest PII", and the decision corrected it —
the fleet already wrote PII safely; that field was different because it was an
**identity key** that entity resolution re-keyed on. Different problem, different
answer. *"A bad phone number is a bad field; a bad email is a corrupted graph."*

**3. A measurable trigger for anything deferred.** Not "later" — *"revisit when
≥10 cases reach the terminal rung (today: 0)."* Deferral with a threshold is a
decision; deferral without one is a hole someone re-escalates in a month.

**4. An explicit directive to the lane**, including what **not** to build, so the
next operator doesn't reopen a settled question.

## Land it where the repo already keeps decisions

If the repo has an existing decision record — a decisions log, an ADR directory,
a table in a project doc — a decision that changes how the repo is built belongs
in **both** places: the full reasoning in `orchestration/<program>/decisions/`,
and a one-line entry in the repo's own log so someone who never reads the bus
still finds it. The orchestrator writes that entry, not the lane.

## Close the loop on the escalation itself

Edit the escalation doc **in place** with a resolved banner and a
**do-not-re-escalate** line pointing at the decision:

```
## STATUS: RESOLVED — RATIFIED (<date>)
This is not an open question — do NOT re-escalate it.
Full record: orchestration/<program>/decisions/DECISION-<date>-<topic>.md
```

Link by **committed repo path**, never by workspace path. A real escalation once
pointed at `../../../<workspace>/docs/decisions/…`, which broke the moment that
worktree was archived — that is why the bus is committed.

Keep the original escalation text below the banner, retained for the record.

## The lane confirms

The lane reports directive-by-directive in its handoff — each ✅ / ⏸ / ⏳ with
what is blocking. That closes the loop verifiably rather than assuming the
decision landed.
