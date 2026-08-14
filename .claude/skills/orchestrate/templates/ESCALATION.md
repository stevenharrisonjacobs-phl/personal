<!-- Escalation template. Written by a LANE crossing an ownership boundary. This
     workspace does NOT decide and does NOT build the thing below — it surfaces
     a gap or a contradiction it hit while doing its own work and requests a
     ruling from the owner. Do not edit the boundary you are escalating about
     (a frozen contract, a shared aggregator, another lane's globs) while you
     wait: continue on whatever is not blocked.

     Write it to orchestration/<program>/escalations/ESCALATION-<date>-<topic>.md,
     commit it on your branch, and tell the approver it is there.

     Escalate only what is NOT answerable from the repo, read-only data, or a
     test. State the evidence, recommend ONE direction, and give the smallest
     concrete set of alternatives with their consequences. -->

# ESCALATION → <decision owner>

**From:** lane <NN> (`<branch>`, workspace `<name>`)
**Date:** <YYYY-MM-DD>
**Trigger:** <the concrete thing that happened — a real case id, a verified
contradiction, a probe result. Not "while reading the spec I wondered".>
**Decision owner:** <orchestrator | approver> (<what they own that you do not>).
**Nothing to approve in this doc** — it requests a <routing | priority | scope>
decision. <Delete this line if the escalation does ask for an approval token,
and name the exact token instead.>

---

<!-- STATUS BANNER — added IN PLACE by the lane when the ruling lands. Until
     then this whole block stays deleted. Never open a second escalation on a
     resolved question. -->

## STATUS: RESOLVED — <one-line disposition> (<date>)

<Decision owner> RATIFIED this. **This is not an open question — do NOT
re-escalate it.** Full record: `<repo path to the DECISION file>`.

Ruling in one paragraph: <the whole ruling, compressed, so a reader who never
opens the decision file cannot act on the stale question. Name what was ruled
IN, what was ruled OUT permanently vs deferred, the preconditions, and the
build trigger if there is one.>

**Directive to this lane from the ruling:** <build nothing / build exactly X /
continue with Y>. All below is the original escalation, retained for the record.

---

## The request

> <One-paragraph framing of the gap, in operational terms. What is now true,
> what should be true, and why no existing governed path covers it.>
>
> **Decide <where and when | which of these | whether at all>:**
>
> 1. **<Dimension — e.g. authority + home>.** <Option A> or <option B>? <The
>    one sentence that makes these genuinely different, not stylistic.>
> 2. **<Dimension — e.g. policy>.** <Question, with the sub-question that is
>    actually load-bearing made explicit.>
> 3. **<Dimension — e.g. priority / build order>** relative to <the current
>    committed work>.
> 4. **<Dimension — e.g. scope>.** <The minimal set, or the full set some
>    earlier spec named?>

## Evidence and constraints the decider needs

- **Do not touch <the boundary>.** <Why — the ratified property of the thing
  that would be breached. Name the contract clause or invariant, and the
  `orchestration/PROFILE.md` section that puts it out of a lane's reach.>
- **What the live system actually shows:** <exact ids, counts, values you
  verified read-only. Population size matters to a priority ruling.>
- **The <signal | artifact | queue> already exists:** `<path or resource>` —
  <so no new detection/plumbing is part of this decision>.
- **The crux is <X>.** <State the sharpest version of the risk, and ask the
  decider to rule on it explicitly rather than by omission.>

## Companion note — already handled, no decision needed

<Anything adjacent that a reader would reasonably assume is also open, but
which is already satisfied. Say why, with evidence, so the decider does not
spend a ruling on it.>

- <fact> — <evidence>. No manual step exists or is needed.

## Lane disposition

Escalating only. This workspace has **not** <edited the boundary / drafted the
contract change / created the writer / changed the policy>. <What it HAS done and
will continue doing while blocked.> Ready to build whatever is scoped and
ratified, on the decision owner's timeline.
