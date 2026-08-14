<!-- Decision template. Written by the ORCHESTRATOR (or the human approver, for
     anything they own) in response to a committed escalation. Write it to
     orchestration/<program>/decisions/DECISION-<date>-<topic>.md and COMMIT it
     — a ratified decision left in an ignored scratch directory dies with the
     worktree, and this has nearly happened twice.

     A decision RULES; it does not discuss. Every substantive question in the
     escalation gets an answer here, including the ones you are declining. Rule
     explicitly on anything ruled out PERMANENTLY versus merely DEFERRED — the
     difference is what stops it being re-escalated.

     After committing: update the escalation's STATUS banner in place. -->

# DECISION — <topic>

**Date:** <YYYY-MM-DD>
**Decided by:** <orchestrator (workspace `<name>`) | approver>
**Escalated by:** lane <NN> (`<branch>`, workspace `<name>`)
**Escalation:** `<repo path to the ESCALATION file>`
**Status:** RATIFIED — <scope, authority, and build order fixed>. <Build
DEFERRED (see §<n>) | Build AUTHORIZED under §<n>.>

---

## Summary of the ruling

| Question | Ruling |
|---|---|
| **<Authority + home>** | <The ruling, compressed to one sentence. Say what it is NOT as well as what it is.> |
| **<Scope (v1)>** | **<the minimal set>.** <How many things that is.> |
| **<The riskiest item>** | **OUT of v1. <Permanently ruled out as X> — not deferred-pending-policy.** |
| **<Approval mode>** | <named policy>, exact-human approval only. No standing policy in v1. |
| **<Priority>** | **P<n> — <deferred \| next>.** Does not jump <the committed work>. |
| **<Build trigger>** | <measurable condition>. Today: **<current value>**. |

---

## 1. <First substantive question — e.g. authority and home>

<The intuitive answer, named, and then why it is wrong. Lead with the deepest
reason, not the most convenient one — test breakage is a symptom, an
incompatible doctrine is a cause. Quote the ratified text that settles it:>

> "<verbatim ratified constraint>" — `<path>`

<The formal corroboration — the named test, guard, or contract clause that would
have to be DELETED to do it the other way. "We do not extend a component by
removing its guarantees."> **<The other candidate> is likewise ruled out and not
reconsidered:** <one line, tied to its declared authority or contract>.

### The ruling, concretely

```
<the exact declared shape: id, domain, authority, allowed operations, allowed
fields, approval modes — so the builder cannot widen it by reading>
```

## 2. <Second question — e.g. scope>

Ruling, item by item:

| Item | Ruling | Why |
|---|---|---|
| `<item>` | **IN v1** | <the genuine gap it closes> |
| `<item>` | **OUT — already solved** | <what already owns it> |
| `<item>` | **OUT — see §<n>** | <one line> |
| `<item>` | **OUT** | <owned by a different owner entirely> |

**<Any way the trigger narrows further than the escalation assumed>.** <State
it with the population numbers that prove it.>

### Preconditions (fail closed on any)

1. <the terminal rung that must be reached — not merely the success response>
2. <the live re-resolution that must hold at preview AND again at apply>
3. <the canonical source the value must come from — never free text>
4. <optimistic lock / conflict check>
5. <exact-human approval of the immutable token>

## 3. <The riskiest question — rule on it explicitly and correct the framing>

<If the escalation framed the risk wrongly, say so and correct it — the framing
is often what determines the answer. Then the N reasons this item is different,
each named and distinct:>

1. **<reason>.** <consequence, in system terms>
2. **<reason>.** <consequence>

**Ruling:** <the ruling>. <What continues to be surfaced without being acted on.>
**If it is ever earned**, the first admissible operation is <the additive,
non-destructive form>, never <the destructive form>. <The destructive form> is
not on the roadmap.

## 4. Priority and build order — P<n>

**The addressable population today is <N>.** <The counts, from a real read-only
check, that make machinery premature or urgent.> **<The urgency argument> does
not survive inspection:** <address the strongest counter-argument directly
rather than ignoring it>.

**BUILD TRIGGER:** revisit when **<measurable condition — e.g. ≥10 cases at the
terminal rung>**. Today: **<current value>**. By then <what will also be true>,
and we will have measured <the thing currently being assumed>.

**Interim handling:** <the manual or partial path>, and <the one honest caveat
about how it will look in the data, so nobody later mistakes it for drift>.

## 5. Directive to lane <NN>

**Build <nothing | exactly the following> from this escalation.** Specifically:

- Do **not** <the boundary change the escalation floated> — this ruling
  reaffirms <the invariant>.
- Do **not** <draft the contract / policy / schema>. It is scoped here and stays
  unbuilt until the build trigger fires.
- **Do** <the thing that is authorized, with its evidence condition>.
- **Continue as planned:** <the in-flight work>, and confirm <the pending
  terminal state> on the next <cycle>.
- Record in the handoff that <this gap> is **ratified, scoped, and deliberately
  deferred** — so the next operator does not re-escalate it as an open question.

<Whether the escalation was correct to route this up rather than build it, and
the disposition of any companion note.>
