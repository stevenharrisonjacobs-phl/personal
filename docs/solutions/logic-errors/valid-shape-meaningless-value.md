---
title: "Shape validation lets meaningless writes land in append-only tables"
date: 2026-09-09
category: logic-errors
module: door/finance_write
problem_type: logic_error
component: data_model
symptoms:
  - "A write reports success and returns landing proof, but the row affects nothing downstream"
  - "A transaction contributes zero to every metric — spending, income, refunds, transfers — at once"
  - "A typo in an enum-like field is accepted because it matches the field's regex"
root_cause: missing_validation
resolution_type: code_fix
severity: high
tags: [validation, enum, append-only, data-integrity, drift-guard]
---

# Shape validation lets meaningless writes land in append-only tables

## Problem

Two write tools validated the *shape* of their arguments and nothing about
their meaning, and both landed rows that were syntactically perfect and
semantically inert:

- `set_flow_override` checked `flow_type` against
  `^[a-z][a-z0-9_]{1,39}$`. `expnese` passes. Gold `COALESCE`s the override
  straight into `gold.transactions.flow_type`, where every metric column is a
  `CASE` over specific literals — so the typo matched none of them and the
  transaction silently contributed **zero** to spending, income, refunds,
  transfers, and investment activity alike.
- `set_vendor_override` and `set_flow_override` accepted any well-formed 64-hex
  `transaction_key` without checking that a transaction has it. Any valid-shaped
  key produced a successful orphan override and misleading landing proof.

Both tables are append-only, so neither mistake is correctable in place — the
bad row stays and the join simply never matches, forever.

## Symptoms

- The write returns `status: ok` with a `row` read back, proving only that the
  override table accepted it.
- Downstream totals are quietly wrong by exactly one transaction, with nothing
  anywhere reporting an error.
- The failure is invisible in the audit log, which records a successful write —
  because it *was* one.

## What Didn't Work

- **A regex that encoded the enum's shape.** `^[a-z][a-z0-9_]{1,39}$` describes
  every value in the vocabulary and infinitely many that are not in it. It
  rejects `"totally not a flow!"` — the case a test covered — and accepts every
  typo of a real value, which is the case that happens.
- **Relying on the read-back as proof.** Both tools read the row back after
  writing. That proves the override landed, not that it *classifies* anything;
  for an orphan key it is landing proof for a row that will never join.
- **Fixing the tool where the bug was reported.** `reclassify_transaction`
  already had the existence check — it was written with the comment that its
  bash twin lacked one. The check simply never propagated to the other two
  members of the same family.

## Solution

Validate against the vocabulary the *consumer* understands, and share the
referential check across the whole family:

```python
FLOW_TYPES = frozenset({
    "adjustment", "cash_withdrawal", "capital_proceeds", "credit_card_payment",
    "earned_income", "expense", "internal_transfer", "investment_activity",
    "investment_income", "needs_review", "refund_reimbursement",
})
```

```python
def _unknown_transaction(tool, actor, args, transaction_key) -> dict | None:
    """None when the key names a real transaction, otherwise the response."""
```

Then pin the enum to its source of truth with a test that reads the SQL:

```python
def test_flow_type_enum_matches_what_gold_actually_recognizes():
    head, _, _ = gold.partition("END AS flow_type")
    case_body = head[head.rindex("\n    CASE"):]
    emitted = set(re.findall(r"THEN '([a-z_]+)'", case_body))
    scored = set(re.findall(r"flow_type = '([a-z_]+)'", gold))
    for group in re.findall(r"flow_type IN \(([^)]*)\)", gold):
        scored |= set(re.findall(r"'([a-z_]+)'", group))
    assert emitted <= fw.FLOW_TYPES   # gold emits nothing the door refuses
    assert scored <= fw.FLOW_TYPES    # gold scores nothing the door refuses
    assert fw.FLOW_TYPES == emitted | scored   # and nothing extra
```

This paid for itself immediately: on first run it failed with
`gold emits values the door refuses: {'adjustment'}` — a real value, emitted
for zero-amount rows, that hand-transcribing the vocabulary had missed. The
enum shipped complete because the test refused to let it ship otherwise.

## Why This Works

The regex answered "is this the right *kind* of value?" when the question that
matters is "is this a value the reader understands?" Those coincide only when
the consumer accepts an open vocabulary. Here the consumer is a SQL `CASE` over
a closed set, so anything outside it is not an unknown-but-harmless value — it
is a value that matches no branch, and a `CASE` with no match returns the
default silently.

The drift guard works because it derives the expectation from the authority
rather than restating it. A hand-maintained enum and a `CASE` in a SQL file are
two copies of one list, and two copies drift. Parsing the SQL makes the test
fail when they diverge in *either* direction — a value gold gained, or a value
the door invented — which is what makes the vocabulary safe to hand-edit later.

## Prevention

- **When a value flows into a `CASE`, a lookup, or a join, validate it against
  that structure's vocabulary — never against its shape.** The tell is a field
  whose legal values are enumerated somewhere else in the system.
- **Derive the test's expectation from the authority.** If a constant mirrors
  a schema, a SQL file, or a config, have the test read that file. Restating
  the list in the test only proves the constant equals itself.
- **Fix a family, not a function.** When one member of a tool family has a
  guard the others lack, the guard is the requirement and its absence is the
  bug. Extract it and apply it across the family in the same change; a
  parametrized test over every member keeps it that way.
- **Weigh validation strictness by reversibility.** Both tables here are
  append-only, so a bad row is permanent. Append-only storage raises the bar on
  input validation, because there is no later correction — only another row.

## Related Issues

- `door/finance_write.py` — `FLOW_TYPES`, `_unknown_transaction`, applied
  across `reclassify_transaction`, `set_vendor_override`, `set_flow_override`.
- `sql/gold.sql` — the `flow_type` `CASE` and the `flow_*` metric columns that
  define the vocabulary.
- `tests/test_door_write.py` — the drift guard and the parametrized
  family-wide existence tests.
