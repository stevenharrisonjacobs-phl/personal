# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## The door and its callers

**Door** — the credentialed service that is the only path from a conversation into the finance mirror. A conversation never holds a warehouse credential of its own; the door holds one and exposes governed tools over it, so what a session can do is defined by the tools it is granted rather than by what it could write directly.

**Mirror** — this project's own warehouse copy of the personal financial record, assembled from bank feeds. Every tool reads the mirror rather than the source systems, so freshness is a property of the last rebuild, not of the bank.

**Machine identity** — a non-interactive caller the door authenticates by a shared-secret bearer token rather than an interactive sign-in. The door stores only digests of these tokens, never the tokens themselves, so a compromised door environment cannot be replayed as a caller.

**Grant** — the permission record for one machine identity: which write tools it may call, which reads it may perform, and whether its classification writes are confined to a daily time window. Default-deny — an identity with no grant is refused everything.

**Window state** — the `human` / `autonomous` stamp carried on every audit row. Interactive callers are always `human`; a machine identity is `human` only while inside its own bounded window, and `autonomous` otherwise, including identities whose grant sets no window at all. It is a claim about whether a person plausibly saw the write land, not about permission.

**Audit row** — the record every write *attempt* leaves, whether it was accepted, changed nothing, or was refused. An accepted write's audit row commits in the same transaction as the data, so the two cannot disagree; a refusal's is written on its own.

## The check-in

**Check-in** — one composed daily spend report, stored as a row rather than a message, so any client that can read the mirror can serve the same morning report.

**Checkpoint** — the end of the period the most recent *successful* check-in covered. The next run's window opens there, which is what makes a missed morning widen the next report rather than lose a day.

**Degraded** — a report state: one named source could not be reached, so its figures are absent while the rest of the report stands. A degraded report is delivered, not withheld; a source that is merely unavailable never shows as zero.

**Stale** — a report state: the mirror's last rebuild was old enough at composition time that the personal figures may lag. Distinct from degraded, which is about a source that failed rather than data that is behind.

**Indeterminate** — a write outcome distinct from both success and failure: the client stopped waiting and the job's fate could not then be established. It exists so a caller is never told a write rolled back when it may have committed, because that is the answer that invites a duplicating retry.

## Classification

**Override** — an append-only correction attached to a single transaction. Nothing is ever mutated or deleted; the most recent override for a transaction wins downstream, so a correction is a new row and the earlier ones remain as history.

**Rule** — a classification instruction keyed by its own identifier, applied to whatever matches it. Unlike an override, re-asking the same key replaces that rule in place, because the consuming views rank rules without deduplicating them and a duplicate key would otherwise apply twice.

**Flow type** — how money *moved* for a transaction: earned, spent, refunded, transferred between owned accounts, or invested. Distinct from the spending category, and a closed vocabulary — a value outside it matches no downstream branch, so the transaction silently counts toward nothing.

## Flagged ambiguities

- "Classification" had been used for both the spending **category** of a transaction and its **flow type** — these are separate axes, and a transaction carries both.
- "Rotating the tokens" had been used for both minting new machine tokens and the full cutover that makes the door accept them — these are separate steps, and the door does not honour new tokens until a revision carrying their digests is promoted.
