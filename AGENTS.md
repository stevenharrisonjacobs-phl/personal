# Financial management agent

This repository mirrors personal Tiller/Copilot finances into BigQuery. It's a
personal project — keep governance light and just get the work done.

## Notes

- Tiller and `tiller_raw` are the upstream source of truth; the underlying data
  is edited in Tiller / the Google Sheet, not here. Everything downstream
  (`finance.*`, `gold.*`) is derived and safe to rebuild via `./scripts/deploy.sh`.
- `./scripts/query.sh <file.sql>` is a convenient runner, but ad-hoc `bq` is fine
  too. Run deploys, rule, and override changes directly when they're warranted —
  no need to ask first.
- The DB can be incomplete when a bank feed silently stops importing. Check with
  `queries/source-freshness.sql` and reconcile against a Copilot export per
  `docs/runbooks/source-reconciliation.md` (match on amount + date + account
  name, never the card mask).
- Always state the date range and whether transfers, refunds, income, and
  uncategorized transactions were included.
- Tiller expenses are negative. Use `finance.v_spending.spend_amount` when
  reporting positive spending.
- Do not treat transfers or credit-card payments as spending. The standard
  queries exclude categories containing `transfer`, but verify unusual cases.
- Add reusable merchant logic with `scripts/add-rule.sh`; use
  `scripts/add-override.sh` for a single transaction.
- **Never commit `.env`, exported transactions, query results, OAuth tokens, or
  service-account keys** — this repo pushes to GitHub. Keep row-level output in
  `.context/` (gitignored).

## Useful views

- `gold.transactions`: the default transaction model. It is deduplicated and
  includes vendor, category, canonical flow type, confidence/evidence,
  cash-flow, and calendar fields.
- `gold.transaction_flow_review`: transactions whose flow cannot be safely
  resolved from source evidence. Never silently coerce these into income or
  transfers.
- `gold.transaction_anomaly_review_queue`: session-reviewed anomalies and source
  ambiguities. Treat suggestions as review material only; never apply them
  automatically.
- `gold.vendors`: one row per inferred vendor with category and spend metrics.
- `gold.accounts`: one row per account with latest balance and activity metrics.
- `gold.categories`: durable category typology derived from Copilot and mapped
  across source systems.
- `gold.category_aliases`: source-to-canonical category mappings for Tiller and
  Copilot.
- `gold.epics`: one row per trip, project, or celebration. Large purchases stay
  in the category model and are not epics.
- `gold.epic_transactions`: Copilot epic assignments with conservative links
  to matching Tiller transactions. Unlinked rows remain part of epic totals.
- `finance.v_transactions_classified`: all normalized transactions plus final
  classification and its source.
- `finance.v_spending`: outflows with positive `spend_amount`.
- `finance.v_current_balances`: latest balance per account.
- `finance.v_monthly_net_worth`: month-end net worth history.

Prefer the `gold` models for analysis. Add exact vendor-name mappings with
`scripts/add-vendor-alias.sh`, regex mappings with `scripts/add-vendor-rule.sh`,
and one-off corrections with `scripts/add-vendor-override.sh`.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:46cd31e7 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->
