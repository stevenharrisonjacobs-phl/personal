---
title: "A client-side query timeout is not a rollback"
date: 2026-09-09
category: database-issues
module: door/finance_write
problem_type: database_issue
component: database
symptoms:
  - "A write tool reports an error, the caller retries, and two rows land"
  - "An append-only override table accumulates duplicate rows with no failed job to explain them"
  - "The audit trail shows one attempt where the data shows two"
root_cause: wrong_api
resolution_type: code_fix
severity: high
tags: [bigquery, timeout, idempotency, transactions, retry]
---

# A client-side query timeout is not a rollback

## Problem

The door's write path bounded its wait on BigQuery
(`job.result(timeout=JOB_RESULT_TIMEOUT)`) and treated the resulting
`TimeoutError` like any other exception: record `job-failed`, return
`{"status": "error"}`. But a `result()` timeout means only that **the client
stopped waiting** — the job keeps running and may commit a second later.
Reporting that as a rolled-back write tells the caller the safest thing it can
do is retry, which is precisely the thing that duplicates an append-only
override or lands a second check-in row.

## Symptoms

- Duplicate rows in append-only tables with no corresponding failed job.
- A caller that "correctly" retried on error is the proximate cause, so the
  retry logic looks right and the write layer looks right.
- Only visible under load or backend slowness, so it survives every test that
  does not simulate a timeout.

## What Didn't Work

- **Bounding the wait, and stopping there.** The bound was itself a good fix
  from an earlier review — an unbounded wait hangs the tool while a half-open
  transaction holds locks. Adding the timeout without giving the timeout its
  own outcome just converted a hang into a wrong answer.
- **Cancelling the job and calling it settled.** `job.cancel()` is worth doing
  so the job stops sitting on locks, but a cancel that arrives after COMMIT is
  a no-op. Cancelling is not the same as knowing.
- **The existing test.** `test_result_timeout_routes_to_job_failed` asserted
  the wrong behavior confidently, which is why the bug shipped: the timeout
  path was covered, and covered as correct.

## Solution

Give "unknown" its own exception, its own reconciliation, and its own status:

```python
class JobIndeterminate(Exception):
    """We stopped waiting on a write job whose outcome is genuinely unknown."""
    def __init__(self, message: str, *, job_id: str | None = None):
        super().__init__(message)
        self.job_id = job_id
```

`_execute` generates a **client-side job id** before submitting, so a job stays
nameable even when the *submit* RPC is what timed out, and converts only
timeouts — never other failures — into `JobIndeterminate`. `_reconcile` then
asks the job API what actually happened and maps it to one of three honest
answers:

| Job state | Reported | Retry? |
|---|---|---|
| `DONE`, `error_result` set | `error`, `reason: job-failed` | yes, nothing landed |
| `DONE`, clean | `ok` / `no-op` + `warning: completed_after_timeout` | no, it committed |
| still running, or unknowable | `indeterminate` | **no** — read the row back first |

`indeterminate` writes its own standalone audit row, because the transactional
audit row lands only if the job commits — without it the trail would show
nothing at all for the attempt.

Reconciliation goes through the **job API**, deliberately, not by re-reading
the target table. The question is whether *our* transaction committed; a table
read cannot distinguish our row from an earlier one with the same key, and a
time-bounded read would need a clock-skew allowance that reintroduces the
ambiguity it is meant to resolve.

## Why This Works

A bounded wait converts one unknown (how long will this take?) into a
different unknown (did it commit?). The error/success binary has no room for
the second unknown, so the code must either invent an answer — which is the
bug — or grow a third outcome.

Naming the third outcome moves the decision to whoever can actually make it.
The write layer knows only "I stopped waiting"; the caller, or the operator,
can read the row back. Returning `indeterminate` with an explicit *do not
retry blindly* is strictly more information than a confident wrong `error`,
and the consuming skill's own instructions were updated to match, so the agent
reading the result does not have to infer the rule.

## Prevention

- **Any bounded wait on a mutation needs three outcomes, not two.** Ask of
  every `timeout=` on a write: what does the caller do when this fires? If the
  answer is "retry," it must first be true that nothing landed.
- **Convert only timeouts.** `_execute`'s single broad `except Exception` is
  the best-effort `job.cancel()`; a test asserts that count stays at 1, so a
  future edit cannot quietly swallow a real failure into the timeout shape.
- **Generate the job id client-side.** Otherwise a submit RPC that times out
  leaves a job that exists and is unnameable — the one case that is genuinely
  unreconcilable.
- **Distrust a test that asserts an error path is an error.** The test that
  encoded this bug read as thorough. Coverage of a path says nothing about
  whether the path's verdict is right.

## Related Issues

- `door/finance_write.py` — `JobIndeterminate`, `_execute`, `_job_outcome`,
  `_reconcile`.
- `sql/door.sql` — the audit result vocabulary gained `indeterminate` as an
  enumerated value distinct from `refused:*`.
- `.claude/skills/spend-checkin/references/generate.md` — the four-outcome
  table the consuming agent reads.
