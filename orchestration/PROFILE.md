# Orchestration profile — personal

**Repo:** `stevenharrisonjacobs-phl/personal` · **Default branch:** `main` · **Last verified:** `2026-08-16`
**Harness schema:** 1

> Re-verify before relying on this file. Stale profile entries are the known
> failure mode — a gate command that no longer exists, or a "safe" action that
> became irreversible, is worse than no profile at all.

This repo is Steven's personal life-automation monorepo: a Tiller→BigQuery
finance mirror, a set of `/`-skills that read mail, calendar, texts, weather and
concerts, and (as of Aug 2026) the `personal-door` MCP server that exposes a
governed slice of it to a Cowork seat. It is a personal repo — governance is
deliberately light. The one thing it is strict about: **row-level financial data
and secrets never reach git.**

---

## 1. Gate commands

```bash
bash scripts/validate.sh              # shell syntax for every scripts/*.sh, then BQ table existence
python3 -m pytest tests/ -q           # door SQL validator + allowlist gate (no GCP needed)
./scripts/query.sh queries/source-freshness.sql   # proves live BQ read auth still works
```

| Command | Exits non-zero on failure? | Currently green? | Notes |
|---|---|---|---|
| `bash scripts/validate.sh` | yes | **yes** — 8,660 txns, 8,660 distinct keys (2026-08-16) | Degrades gracefully: with no `.env` it checks shell syntax only and exits 0. That is a **soft pass** — read the output, don't trust the exit code alone. |
| `uv run --with pytest --with google-cloud-bigquery python -m pytest tests/ -q` | yes | **yes** — 45 passed | No GCP or network. Plain `python3 -m pytest` fails on this machine: pytest is not in the system interpreter. |
| `./scripts/sync-cowork-plugin.sh --check` | yes | **yes** | Fails if the plugin is stale relative to `.claude/skills/`. Run before any plugin release. |
| `./scripts/query.sh queries/source-freshness.sql` | yes | **yes** | Needs `.env` **and** active gcloud auth. See hazards. |
| `./scripts/deploy-door.sh probe` | yes | n/a — nothing deployed yet | Post-deploy health. **401 is healthy** (auth required); 404 means the wrong image shipped. |

**Known-bad baselines:** none.

**What runs automatically:** **nothing in CI — there is no `.github/`.** The
operator is the CI. What *does* run automatically is outside the repo: the
hourly "Tiller hourly mirror" BigQuery scheduled query, and the
`com.stevenjacobs.philly-shows` launchd job. Neither is exercised by any gate
here, so a change to `sql/refresh.sql` is only proven by deploying it.

## 2. The ladder

```
repo edit → branch → merged to main → BQ model deployed (deploy.sh) → door image on Cloud Run → connector/plugin live in claude.ai
```

| Rung | What proves it | Reversible? |
|---|---|---|
| repo edit | gates above | yes |
| merged to `main` | `git log origin/main` | yes (revert) |
| BQ model deployed | `scripts/validate.sh` finds every table; `queries/*` return | **no** — see §4 |
| door on Cloud Run | `door_whoami` returns the enrolled identity | **no** — public URL |
| connector/plugin live | a fresh Cowork session auto-invokes `/finances` | **no** — changes what every future session can reach |

**The point of no return is the Cloud Run deploy** — it publishes a
publicly-reachable URL fronting the complete finance mirror. From that moment
the door's own allowlist is the only perimeter, so it is the one thing that must
never ship unverified. `deploy.sh` is a second, quieter point of no return: it
rewrites views *and* the hourly scheduled query, and a scheduler change is not
undone by a git revert.

## 3. Shared aggregators — orchestrator-owned

- `AGENTS.md` — the repo's context file; every workstream wants a line in it.
- `.env.example` — every new integration adds keys; merges badly because
  additions cluster at the end.
- `sql/gold.sql` — the single largest model file, and the one three finance
  workstreams all touch.
- `.claude/skills/finances/SKILL.md` — the router. Adding a branch is a one-line
  edit that every branch author wants to make.
- `projects/INDEX.md` — the tracker; `/park` and `/groom` both write it.

**Mandated exceptions** — none.

**Known-nasty merges:**

- `cowork/plugins/personal/skills/**` is **generated** by
  `scripts/sync-cowork-plugin.sh` from `.claude/skills/`. Never hand-edit it and
  never hand-merge it — regenerate.
- `.env` is gitignored and diverges per worktree (see hazards).

## 4. Irreversible and external actions

| Action | Why it's hard to undo | Who approves |
|---|---|---|
| `gcloud run deploy personal-door` | Publishes a public URL fronting the entire finance mirror. The door's allowlist becomes the only perimeter. | Steven |
| Creating / publishing the Google OAuth client | An external-facing identity surface on his Google account; publishing to Production is a state change at Google. | Steven |
| Writing secrets to Secret Manager (`JWT_SIGNING_KEY`, `STORAGE_ENCRYPTION_KEY`, OAuth secret) | Rotating them later invalidates every live connector session. | Steven |
| Adding the connector or plugin in claude.ai | Changes what every future Cowork session can reach, on every device. | Steven |
| `./scripts/deploy.sh` | DDL over `finance.*`/`gold.*` **and** rewrites the hourly scheduled query. Views rebuild; a broken scheduled query silently stops mirroring. | Steven |
| Any future door tool that writes `finance.*`/`gold.*` | A classification write from a phone reshapes the books with no review step. | Steven |
| `scripts/shows_email.py` send, and any Gmail send path | External send. Leaves the machine. | Steven |

**Hard bans** — no approval covers these:

- Committing row-level financial data, merchant/amount exports, query results,
  OAuth tokens, or service-account keys. Row-level output lives in `.context/`.
- Removing or weakening the door's email allowlist, or shipping a door tool that
  does not route through the `_authorize` gate.
- Adding `tiller_raw.*` to the door's source whitelist — those are external
  tables over the Google Sheet and would drag Drive credentials into the door.
  (The read-only classification lookups are *in* the catalog deliberately; the
  boundary that matters is Drive, not "looks writable". See spec §5.1.)
- Writing to Tiller or to `tiller_raw.*` from anywhere in this repo. Tiller is
  upstream and is edited in the Sheet.
- Auto-sending email.

## 5. Review lenses

1. **The allowlist actually holds.** Probe: call a governed tool with a token
   whose email is not enrolled and with `email_verified` false — both must
   refuse. Do not read `_authorize` and reason about it; execute it.
2. **The SQL validator cannot be walked around.** Probe: feed it a `SELECT`
   with a whitelisted table in a comment and `tiller_raw` in the real `FROM`; a
   trailing second statement; a `FROM` reached through a CTE alias shadowing a
   real name. Each must be rejected.
3. **Door numbers equal laptop numbers.** Probe: run the same question through
   `run_finance_query` and through `./scripts/query.sh` and diff. A door that
   disagrees with the laptop is a bug, not rounding.
4. **Nothing sensitive reached git.** Probe: `git diff --cached` for amounts,
   merchant names, account numbers, and any `.env`-shaped line before every
   commit.
5. **Freshness is not assumed.** Probe: any finance answer must survive
   `queries/source-freshness.sql` — a stale feed makes a confident answer wrong,
   which is exactly how three mortgage payments went missing.

## 6. Frozen contracts

| Artifact | What it fixes | Owner | Consumers |
|---|---|---|---|
| `door/service.py` `_authorize` | The identity gate every tool passes through | orchestrator | every door tool |
| `door/finance_native.py` `SOURCES` | The governed source whitelist | orchestrator | door tools, skills, context docs |
| `.claude/skills/personal/SKILL.md` transport rule | Door-first / `query.sh`-fallback, never both | orchestrator | every personal skill |
| `cowork/plugins/personal/.claude-plugin/plugin.json` | The plugin's name — renaming uninstalls it for the user | orchestrator | the claude.ai seat |

**A change to any of these is an escalation.**

---

## Lane boundaries

- `door/**` + `tests/**` — the MCP server
- `.claude/skills/**` — skills and context library
- `cowork/**` + `scripts/sync-cowork-plugin.sh` — plugin packaging
- `sql/**` + `queries/**` — the BigQuery model
- `scripts/*.py` — the personal data-access layer (mail/calendar/texts/weather)

## Repo hazards

- **`.env` is gitignored and diverges per worktree.** A fresh Conductor
  workspace often lacks the finance block, and `query.sh` then dies at
  `load_env`. Append it; do not overwrite the file.
- **Wrong-tenant gcloud account.** The machine's active account may be a Snapfix
  or Bobsled identity. Finance reads need `steven@plumgrowth.ai`.
- **`deploy.sh` needs Drive + BigQuery in one credential.** Plain
  `gcloud auth login` reuses a cached no-Drive token; `--force
  --enable-gdrive-access` is required. Day-to-day mirroring does not need this.
- **A connector's tool list snapshots at add-time.** Any door release that
  changes the toolset requires removing and re-adding the connector — a redeploy
  and even a re-auth are not enough.
- **Plugin sync is not near-real-time.** Expect a manual update in the Plugins
  panel after a release.
- **Copilot expenses are positive; Tiller's are negative.** Compare `ABS` when
  reconciling, and never match on the card mask — masks diverge between systems.
