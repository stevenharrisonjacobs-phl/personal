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

Reach for `saved_query` before novel SQL: a saved query already encodes the sign
conventions and exclusions for its question.

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

- **The door is read-only.** It has no write tools, by design. From a Cowork
  seat you can *diagnose* anything and *change* nothing.
- Classification changes (rules, overrides, vendor aliases) and `deploy.sh` are
  **Claude Code, in the repo, with Steven present**. From anywhere else, say what
  should change and stop.
- Tiller is upstream. Never write `tiller_raw.*` or the Google Sheet.
- **Never commit row-level data** — merchants, amounts, account numbers, query
  results. `.context/` is gitignored; that is where output goes.
- Never auto-send email.

## Reporting rules that make an answer correct

Every finance answer states **the date range** and **whether transfers, refunds,
income, and uncategorized transactions were included**. Prefer aggregates; do not
print account numbers or transaction ids unless genuinely needed. A clean table
beats a chart unless the chart earns its place.
