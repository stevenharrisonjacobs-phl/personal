---
name: personal
description: Shared runbook for ALL personal skills — how to reach Steven's data (the personal-door MCP connector first, local scripts as fallback), the door's tool catalog, the context library index, and the write discipline. Load this whenever a personal skill runs (finances and friends), or whenever a task needs to read the finance mirror from outside the repo.
---

# The personal door — shared runbook

## Transport: door first, local scripts as fallback

**Preferred — the `personal-door` MCP connector.** If tools named `door_whoami`,
`run_finance_query`, `saved_query`, … are available in this session, use them for
everything. Call `door_whoami` once at the start. If it reports
`authorized: false`, say so and stop — the fix is reconnecting with the enrolled
Google account, never a retry, and never a workaround.

**Fallback — local scripts.** Only when the door's tools are NOT available,
which means you are in Claude Code against the repo:

```bash
./scripts/query.sh .context/<name>.sql
```

Write a **comment-free** `.sql` file into `.context/` first — a leading `--`
comment breaks `query.sh`, which strips to the next `;`. `.context/` is
gitignored, which is where row-level output belongs.

Say which transport you are using if asked. **Never mix both in one session** —
two transports means two answers to reconcile and no way to tell which is right.

## The door's catalog

| Tool | Use it for |
|---|---|
| `door_whoami()` | identity + enrollment check; first call of a session |
| `feed_health()` | **run before trusting any answer** — is a bank feed silently dead? |
| `list_saved_queries()` | the vetted questions that already have proven SQL |
| `saved_query(name, max_rows?)` | run one of them |
| `list_finance_sources()` | the governed source catalog with grain and purpose |
| `describe_finance_source(source)` | live schema for one source — never guess columns |
| `run_finance_query(sql, max_rows?, dry_run?)` | one capped read-only SELECT/WITH |

The door also exposes **write tools, granted per intent** — a session only
sees the ones its token's grant carries, and a missing write tool means "not
from here", never a gap to work around:

| Tool | Use it for |
|---|---|
| `record_checkin(payload)` / `record_checkin_failed(reason)` | landing the daily check-in row — generation runs only |
| `reclassify_transaction(transaction_key, category, notes?)` | correcting one transaction's category |
| `set_vendor_override(transaction_key, vendor_name, notes?)` | fixing one mis-resolved vendor |
| `set_flow_override(transaction_key, flow_type, notes?)` | fixing one flow_type, clearing it from flow review |
| `add_vendor_mapping(vendor_name, category_id, notes?)` | mapping a known merchant to a canonical category |
| `add_vendor_alias(alias_name, canonical_vendor_name, notes?)` | collapsing a descriptor variant onto its merchant |
| `add_classification_rule(...)` / `add_vendor_rule(...)` | regex rules for merchants not yet seen |

Every write is an append — latest row wins; undo is a restoring append, never
a delete. Classification writes work only inside the human window
(06:45–23:00 ET); outside it the door refuses, by design.

Reach for `saved_query` before novel SQL: a saved query already encodes the sign
conventions and exclusions for its question. The morning spend report is
`saved_query("latest-spend-checkin")` — the `/spend-checkin` skill wraps it.

Errors come back as `{status, error}`. **Quote them verbatim.** A `forbidden` is
never retried and never routed around. If the tools are missing entirely, the
connector needs its updated toolset — a connector snapshots its tool list when it
is added, so it must be removed and re-added after a door release. Say that;
don't guess at a substitute.

**Never use raw BigQuery from a Cowork seat**, and never ask for the door to be
bypassed. The whitelist, byte caps, and redaction are the reason the door is safe
to expose at all.

## Context library

Business meaning lives in `.claude/skills/finances/context/`, not in skill files.
Read the ones the task needs:

| Doc | Read it when |
|---|---|
| `context/definitions.md` | **before any SQL or metric claim** — sign conventions, flow types, join traps |
| `context/accounts.md` | judging feed freshness, or which accounts are off-mirror |
| `context/verified-queries.md` | before writing novel SQL — adapt a proven one |
| `context/household.md` | advisor framing — the unit of analysis, the tax haircut |

Each carries `last-reviewed` and `update-when`. If a doc is past its review
window, caveat it rather than trusting it silently. When an answer goes wrong
because a doc is stale, the fix is editing the doc — not patching the skill.

## Write discipline

- **The door's writes are granted per intent.** The door is no longer
  read-only: it exposes exactly the write tools a session's grant carries
  (check-in recording, classification corrections). No grant, no tool — and
  the refusal of an ungranted or out-of-window write is the design working,
  never something to retry or route around.
- Classification changes (rules, overrides, vendor mappings/aliases) may go
  through the door's write tools **with Steven present** — the cloud morning
  session with Steven in it qualifies. The triage rubric still applies
  (reversibility first, narrowest write-scope), and every door write follows
  the write protocol in the spend-checkin skill's `references/interactive.md`:
  Steven's explicit ask → echo the resolved parameters → call → show the
  landing proof. Autonomous sessions never classify — the human window
  (06:45–23:00 ET) enforces that door-side.
- `deploy.sh` and edits to committed context files remain **Claude Code, in
  the repo, with Steven present**. From a cloud or Cowork session, curation is
  narrate-and-relay: state the exact proposed edit (file, section, line) and
  stop — never attempt git operations from there.
- Tiller is upstream. Never write `tiller_raw.*` or the Google Sheet.
- **Never commit row-level data** — merchants, amounts, account numbers, query
  results. `.context/` is gitignored; that is where output goes.
- Never auto-send email.

## Reporting rules that make an answer correct

Every finance answer states **the date range** and **whether transfers, refunds,
income, and uncategorized transactions were included**. Prefer aggregates; do not
print account numbers or transaction ids unless genuinely needed. A clean table
beats a chart unless the chart earns its place.
