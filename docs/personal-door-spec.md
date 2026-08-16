# The personal door — spec + build plan

**What:** one remote MCP server (`personal-door`) plus one skills plugin, so
`/finances` (and later everything else in this repo) works from a **Cowork** seat
on claude.ai — no laptop, no `bq`, no `.env`.

**Status:** spec. Nothing built. Nothing deployed.

**MVP success test:** in Cowork, "what did we spend on dining in July?" returns a
correct, sourced answer with the date-range/exclusions disclosure — and a Google
account that isn't Steven's gets a hard refusal from the same URL.

## 0. Scope boundary — pattern, not payload

**We are rebuilding the Snapfix delivery mechanism for personal use. We are not
porting any Snapfix content, and the two systems share nothing at runtime.**

| Copied (shape) | Not copied (content) |
|---|---|
| The two-switch architecture: plugin for skills, MCP connector for data | Snapfix skills — `signals`, `review-plays`, `generate-plays`, `graduate`, `feedback`, `brief`, `ask` |
| FastMCP-on-Cloud-Run + per-user OAuth as the server pattern | Auth0, the Snapfix app API, `X-Acting-User` delegation |
| The governed-SQL idea: catalog → describe → validated capped query | The GTM source whitelist, `account_info`, call-insight and transcript tools |
| The context-library convention (owner + `update-when` headers) | Every Snapfix context doc — `company.md`, `definitions.md`, `priorities.md`, `verified-queries.md`, `facet-catalog.md` |
| Marketplace repo layout and the transport switch in skills | Lanes (`dev`/`prod`/`deploy`), admin gates, tenancy — meaningless with one user |

No shared repo, no shared GCP project, no shared credential, no data path
between them. This matters beyond tidiness: Snapfix is a client tenant, and the
tenant-isolation rule in `~/.claude/CLAUDE.md` means these two must never share
a runtime.

**The one literal code port** is `_validate_query` from
`snapfix/door/gtm_native.py` — ~40 lines of generic SQL-safety regex, no Snapfix
semantics in it. Plum Growth authored it, so there is no ownership question;
it's called out here so "no content copied" stays a true statement rather than
an approximate one. Its source whitelist is replaced wholesale (§5.1).

### Two templates, not one

| Source | What we take |
|---|---|
| **Snapfix door** (`~/conductor/repos/snapfix/door/`) | The *distribution* pattern: plugin marketplace, connector, governed SQL, context library, transport switch |
| **Bobsled door** (`~/conductor/workspaces/bobsled-agents/karachi/door/`) | The *auth* implementation — Google OAuth, the allowlist gate, encrypted persistent OAuth state, and the `auth.py`/`service.py`/`main.py` split |

Bobsled's is the newer and more hardened of the two, and §4 follows it closely
rather than re-deriving anything from the FastMCP docs. Same "pattern, not
payload" rule applies: none of Bobsled's domains, catalogs, or evaluation
machinery comes across.

---

## 1. Review of the Snapfix door (what we're copying)

Source of truth read for this spec: `~/conductor/repos/snapfix/door/` (main.py,
gtm_native.py, account_info.py), `~/conductor/repos/snapfix/cowork/`, and
`docs/ai-sales-ops/cowork-distribution-design.md` including its de-risk log.

### Its shape

```
GitHub repo ──[plugin marketplace, auto-sync]──► every Cowork seat   (skills + context)
snapfix-door on Cloud Run ──[custom connector, per-user OAuth]──► every seat   (data + actions)
```

Two switches. Onboarding is "accept the plugin, click Connect, log in." Nothing
on disk, no tokens handed out.

### The five ideas worth stealing verbatim

| Idea | Why it matters |
|---|---|
| **Governed SQL, not a BQ client.** `run_gtm_query` accepts one `SELECT`/`WITH`, validates every `FROM`/`JOIN` against a hard-coded source whitelist, rejects DML/DDL/`ML.`/`EXTERNAL_QUERY`, dry-runs first, caps bytes billed and rows. | The model gets analytical freedom without getting the warehouse. This is the single best piece of the design. |
| **Source catalog as a tool.** `list_gtm_sources` → `describe_gtm_source` → write SQL. Schema comes from the live table, never from the model's memory. | Kills hallucinated columns. |
| **Context library shipped in the plugin.** `context/definitions.md` (semantics + join traps), `verified-queries.md` (proven question→SQL pairs), each with an owner and `update-when` triggers. | Skills are behavior contracts; context docs are what the business *means*. Wrong answers get fixed by editing a doc, not code. |
| **Transport switch in the shared skill.** "Door tools if present; documented fallback otherwise; never mix both in one session." | One skill body works in Cowork *and* in Claude Code. No fork. |
| **Refusals are relayed, not routed around.** Tools return `{error, status}`; the skill quotes it and never retries a 403. | Server-side rules stay authoritative. |

### The three things that must change for personal

| Snapfix | Personal | Why |
|---|---|---|
| Auth0 (the app's existing IdP), with a `_extract_upstream_claims` override because FastMCP's proxy discards upstream identity | **Google OAuth** (`fastmcp.server.auth.providers.google.GoogleProvider`) | No Auth0 here. Google's verifier already puts `email` in the claims, so the override isn't needed. |
| Identity is *transported* (X-Acting-User) to an app that decides privilege; many people, tenant-scoped | **Identity is the gate.** One person. A hard email allowlist, or nothing. | There is no downstream app to enforce anything. The door *is* the perimeter. |
| ~21 tools including writes (verdicts, screening, generation, graduation) | **Read-only MVP.** Zero writes. | Every finance write here is either a classification change or `deploy.sh` — both belong in Claude Code where the triage rubric applies. |

### Known platform gotchas, inherited (all from the Snapfix de-risk log)

1. **A connector's tool list snapshots at add-time.** Redeploying the door with a
   changed toolset is not enough — the connector must be **removed and re-added**.
   Every tool-changing release needs this in its note.
2. **Plugin sync is not near-real-time.** Assume a manual "update" in the Plugins
   panel after each release.
3. **OAuth state on ephemeral Cloud Run disk is a real bug**, not a nitpick.
   Snapfix's stopgap was pinning one warm instance. §4.3 does better.
4. **Verify writes at the system of record, never from the client's echo.** The
   Snapfix door once reported a write as attributed to the rep while the app had
   silently ignored the header. Only matters when we add writes, but it's the
   most expensive lesson in the log.

---

## 2. Target architecture

```
github.com/stevenharrisonjacobs-phl/personal  (private)
  cowork/  ──[Customize ▸ Plugins ▸ Add from a repository]──►  Steven's Cowork seat
    skills/   personal (shared runbook) + finances (router & branches)
    context/  definitions, verified-queries, accounts, household

personal-door  (Cloud Run, us-central1, project steven-tiller-finance-2026)
  FastMCP + GoogleProvider OAuth  ──[Customize ▸ Connectors ▸ custom connector]──►  same seat
  └─ read tools over BigQuery finance.* / gold.*  (runtime SA, workload identity)
     hard email allowlist enforced on every call
```

Claude Code keeps working exactly as today — `scripts/query.sh` against local
`bq`. The skill picks the transport; the answer is the same either way.

---

## 3. Repo layout

```
door/                       # new — the MCP server (mirrors bobsled-agents/door/)
  main.py                   #   thin tool declarations only
  auth.py                   #   Google OAuth wiring + Identity  (port of Bobsled's)
  service.py                #   DoorPolicy/_authorize + governed delegation
  finance_native.py         #   governed SQL: catalog, validator, runner
  saved_queries.py          #   runs queries/*.sql by name
  requirements.txt
  Dockerfile
  .env.example
  .gcloudignore
cowork/                     # new — the plugin marketplace
  .claude-plugin/marketplace.json
  plugins/personal/
    .claude-plugin/plugin.json
    skills/                 #   generated by scripts/sync-cowork-plugin.sh
scripts/
  sync-cowork-plugin.sh     # new — .claude/skills/* → cowork/plugins/personal/skills/*
  deploy-door.sh            # new — the gcloud run deploy, with a confirmation prompt
.claude/skills/
  personal/SKILL.md         # new — shared runbook (transport, catalog, guardrails)
  finances/                 # edited — transport switch + context/
    context/*.md            # new — the context library
tests/test_door_sql.py      # new — validator tests, run without GCP
```

`.claude/skills/` stays canonical (it is also the source of the globally
symlinked harness skills). The plugin is **generated** from it, never
hand-edited — same anti-drift rule Snapfix uses for its context sync.

---

## 4. Auth and security

This is the part that actually matters. The Cloud Run URL must be publicly
reachable for claude.ai to call it, so the door's own auth is the *only* thing
between the open internet and a complete picture of Steven's finances.

**Decision: Google, not Auth0** — matching the Bobsled door. Auth0 only appeared
in the Snapfix design because it was already that app's IdP; there is no reason
to introduce it here. `door/auth.py` is a near-verbatim port of
`bobsled-agents/door/auth.py`, with the names changed and one substitution (§4.3).

### 4.1 Provider

`GoogleProvider` (FastMCP 3.4.x), configured exactly as Bobsled's:

| Setting | Value |
|---|---|
| OAuth client | Web application, created in `steven-tiller-finance-2026` |
| Redirect URI | `https://<cloud-run-url>/auth/callback` |
| `required_scopes` | `openid`, `profile`, `https://www.googleapis.com/auth/userinfo.email` |
| Publishing status | **Production**, not Testing |
| Env | `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`, `BASE_URL` |

**Fails closed.** Missing client id or secret raises `DoorConfigurationError` at
startup. No-auth mode exists only for local dev and only when `BASE_URL` is
loopback *and* an explicit insecure flag is set — the check is on the hostname,
so a misconfigured production deploy cannot fall through to it.

Publishing status is not cosmetic: Google expires refresh tokens after **7 days**
for apps left in Testing, which would mean reconnecting weekly. These scopes are
non-sensitive, so Production needs no Google verification review.

### 4.2 The allowlist (non-negotiable)

`GoogleProvider` authenticates *anyone with a Google account*. On its own that is
an open door to the whole finance mirror. Port Bobsled's `DoorPolicy` /
`_authorize` gate, which runs three checks in order before any tool does work:

1. subject **and** email present, else `unauthorized`
2. `email_verified is True` — strictly `True`, not truthy, since Google's
   token-info endpoint returns the string `"true"` and the port normalizes it
3. email in `PERSONAL_DOOR_ALLOWED_EMAILS`, else `forbidden`

Two details worth keeping from the Bobsled version:

- **`door_whoami` is deliberately ungated.** It answers for an unenrolled
  identity too, returning `authorized: false`. So a wrong-account connection
  produces a clear diagnosis instead of a silent failure — while still yielding
  no data.
- **Authorization lives in `service.py`, not in the tool functions.** Every
  governed method calls `_authorize` first, so a tool added later cannot ship
  unprotected by forgetting a decorator.

**The door refuses to start if the allowlist is empty.** No permissive default.

Which account to enroll is Steven's open decision (§11.1) — the Snapfix door
proved connector identity is decoupled from the claude.ai seat identity, so the
seat being `steven@bobsled.co` does not constrain the choice.

### 4.3 OAuth state durability — Bobsled's pattern, Firestore instead of Redis

FastMCP stores dynamic client registrations and encrypted tokens under
`FASTMCP_HOME`. On Cloud Run that is ephemeral, so a cold start or redeploy
loses the registration and the connector breaks. Snapfix pinned a warm instance
as a stopgap; **Bobsled solved it properly** with an encrypted persistent
key-value store, and refuses to start in production without one.

Take that design whole, with one substitution:

| | Bobsled | Personal |
|---|---|---|
| Store | `RedisStore` (Memorystore) | **`FirestoreStore`** — same `key-value-aio` library |
| Encryption | `FernetEncryptionWrapper` + `STORAGE_ENCRYPTION_KEY` | identical |
| JWT | `jwt_signing_key` from Secret Manager | identical |
| Cost | ~$40/mo, justified for a multi-seat company door | **~$0** — serverless, inside the free tier at one user |

Keep the fail-closed guard verbatim: a non-loopback `BASE_URL` without
persistent storage configured raises at startup, with a single documented
escape-hatch env var that says in its own error message that it will force a
reconnect after any restart.

This retires the GCS-FUSE idea from the first draft of this spec — it was a
worse answer to a problem already solved next door.

### 4.4 Data handling

- Runtime service account: BigQuery **Data Viewer + Job User** on
  `steven-tiller-finance-2026` only. No Drive scope, no write roles, no key file
  (workload identity).
- `tiller_raw.*` is **excluded from the whitelist** — those are external tables
  over the Google Sheet, needing Drive credentials the door deliberately lacks.
  Everything goes through `finance.*` / `gold.*`.
- Row caps and byte caps on every query (§5.2).
- Account numbers and masks are redacted door-side before results leave the
  server; aggregates are the default and row-level output is opt-in.

---

## 5. Tool catalog — MVP

Read-only. Every tool returns `{error, status}` on refusal rather than raising.

| Tool | Signature | Purpose |
|---|---|---|
| `door_whoami` | `()` | Which Google identity this session is. First call of any session; also the allowlist proof. |
| `list_finance_sources` | `()` | The governed source catalog — each view's grain and purpose. |
| `describe_finance_source` | `(source)` | Live BigQuery schema for one source. Never guess columns. |
| `run_finance_query` | `(sql, max_rows=100, dry_run=False)` | One capped read-only `SELECT`/`WITH` over the whitelist. |
| `saved_query` | `(name)` | Run a proven query from `queries/*.sql` by name. |
| `feed_health` | `()` | Per-account latest transaction date, `days_since_latest`, `txns_last_30d`. |

`saved_query` and `feed_health` are not sugar. `feed_health` is step 1 of the
update branch and guards the repo's #1 data-integrity failure — *a bank feed
silently stops and the answer is quietly wrong*. `saved_query` gives the model a
correct path for the dozen questions that already have vetted SQL, instead of
re-deriving `spend_amount` sign conventions each time.

### 5.1 Source whitelist (seed)

From `AGENTS.md` "Useful views" plus the live dataset listing:

**gold** — `transactions`, `transactions_base`, `vendors`, `accounts`,
`categories`, `category_aliases`, `epics`, `epic_transactions`,
`transaction_flow_review`, `transaction_anomaly_review_queue`,
`vendor_canonical_review`, `v_projection`, `v_accrued_costs`,
`v_spending_accrued`, `v_spending_amortized`, `v_business_revenue_monthly`,
`amortization_schedule`

**finance** — `v_transactions_classified`, `v_spending`, `v_current_balances`,
`v_monthly_net_worth`, `v_manual_income`, `v_assumptions_current`,
`manual_balances`, `manual_income`, `balance_history`, `accruals`, `assumptions`

**classification lookups (read-only)** — `gold.vendor_aliases`,
`gold.vendor_rules`, `gold.vendor_category_map`,
`gold.transaction_vendor_overrides`, `gold.transaction_flow_overrides`,
`gold.epic_definitions`, `finance.classification_rules`,
`finance.transaction_overrides`

> These last eight were excluded in the first draft as "the write surface", and
> that was wrong. The door has **no write tools at all**, so there is no write
> path to invite; they hold mappings and notes, not amounts; and excluding them
> silently broke a vetted saved query (`vendor-aliases`) while removing any way
> to answer "why is this vendor labelled that?". A stale or broken vetted query
> is the failure this catalog exists to prevent. `tests/test_door_sql.py`
> now asserts every saved query is runnable, so the same mistake fails loudly.

**Deliberately absent:** everything in `tiller_raw` — external tables over the
Google Sheet, whose exclusion is a real technical boundary (they need Drive
credentials the door does not and must not hold), not a precaution. Also absent:
the onboarding/ops tables and `finance.transactions` (superseded by
`gold.transactions`).

**Measured 2026-08-16:** all 36 whitelisted sources resolve against live
BigQuery, all 17 saved queries run, and `tiller_raw` is refused with an
explanatory error.

### 5.2 Validator rules (port of `gtm_native._validate_query`)

Single statement · `SELECT`/`WITH` only · no `INSERT|UPDATE|DELETE|MERGE|CREATE|
DROP|ALTER|TRUNCATE|CALL|EXPORT|LOAD|GRANT|REVOKE` · no `EXTERNAL_QUERY`/`ML.`/
`AI.` · every qualified `FROM`/`JOIN` target must be `steven-tiller-finance-2026`
+ (`finance`|`gold`) + a whitelisted table · CTE references allowed · comments and
string literals masked before matching · **dry-run first**, then execute with
`maximum_bytes_billed` (1 GiB is generous for these datasets) and `max_rows ≤ 500`.

Tested without GCP: the validator is a pure function, so
`tests/test_door_sql.py` covers accept/reject cases offline.

---

## 6. Context library

New, under `.claude/skills/finances/context/`, shipped inside the plugin. Each
doc gets a header with `owner` and `update-when`, per the Snapfix framework.

| Doc | Holds |
|---|---|
| `definitions.md` | The semantic layer. Tiller expenses are negative; use `v_spending.spend_amount` for positive spend. `flow_type` vocabulary. Transfers and card payments are not spending. `gold` vs `finance`. **The `manual_income` additive rule** (Hannah's 401(k) deferral is *not* a double-count against her take-home). The `COALESCE(institution,'') != 'Mercury'` NULL trap. |
| `verified-queries.md` | Question → SQL pairs proven against the warehouse. Seeded from `queries/*.sql`. |
| `accounts.md` | Which accounts are actively fed vs naturally stale (trusts, retirement). Without this, `feed_health` produces false alarms. |
| `household.md` | Durable framing facts for the advisor branch — household + business as one unit, the three-tier monthly nut, the income tax haircut. |

`household.md` is the one genuinely sensitive doc. It ships only to Steven's own
seat from his own private repo, and holds *framing*, never balances.

---

## 7. Skills

### `personal` — the shared runbook (new)

The Snapfix `snapfix/SKILL.md` analogue. Transport switch, tool catalog, the
context-library index, guardrails. Loaded by every other personal skill.

Transport rule, verbatim in spirit from Snapfix:

> If `door_whoami`, `run_finance_query`, … are available, use them for
> everything — call `door_whoami` once at the start. If they are **not**
> available, you are in Claude Code against the repo: use `./scripts/query.sh`
> with a comment-free `.sql` file in `.context/`. Say which transport you're
> using if asked. Never mix both in one session.

### `finances` — edited, not rewritten

Today it routes to two branches. Changes:

1. Router gains the **Advisor review** branch (`references/cash-flow-review.md`)
   — recorded in memory as existing, but **not present in the repo on `main`**.
   It needs to be reconstructed from the iCloud archive at
   `~/Library/Mobile Documents/com~apple~CloudDocs/conductor-archives/seattle-2026-08-11/`.
   Flagging this because the spec assumes three branches and only two exist.
2. `analyze-data.md` gets the transport switch: door tools first, `query.sh`
   fallback. The disclosure rules (date range, exclusions) are unchanged.
3. `update-database.md` gets a **Cowork ceiling**: from a Cowork seat it can
   *diagnose* (`feed_health`, review queues) but cannot *fix*. Fixes —
   rules, overrides, `deploy.sh` — say "do this in Claude Code" and stop.

---

## 8. Explicitly out of MVP scope

| Not building | Why | When |
|---|---|---|
| Any write tool | Every finance write is a classification change or a deploy; both need the triage rubric | Phase 6, as propose→confirm→write to a classification table. Never `deploy.sh`. |
| Copilot reconciliation from Cowork | Needs a CSV upload path and row-level handling | Later, if ever — it is a laptop job |
| Other domains (`/morning`, `/inbound`, `/shows`, `/weather`) | They need Gmail/Calendar/iMessage credentials, a different and larger auth story | Phase 7+, one domain at a time, same door |
| Multi-user anything | There is one user | Never |

---

## 9. Cost

| Item | Est. |
|---|---|
| Cloud Run, scale-to-zero | ~$0–2/mo |
| Firestore OAuth state | ~$0 — free tier covers one user comfortably |
| BigQuery scans | cents — these datasets are small and every query is capped |
| Secret Manager | pennies |

Firestore over Redis is the difference between ~$0 and ~$40/mo. Memorystore is
the right call for a company door with seats to add; it is pure waste for one
person.

---

## 10. Build plan

**Triage: reversible up to each named gate; one dominant write-scope → solo,
with hard stops.** Not a program. The work is sequential and the scopes
(`door/`, `cowork/`, `.claude/skills/`) do not overlap enough to justify lanes —
but four steps are irreversible and each one stops for Steven.

### Harness instantiation (Phase 0 — needs Steven's go-ahead)

`harness-doctor.sh` reports: context file ✅ (`AGENTS.md`) · orchestration
**MISSING** · task graph **MISSING**.

| Artifact | Verdict |
|---|---|
| `orchestration/PROFILE.md` | **Warranted now.** This repo is about to gain four irreversible actions (§below) and currently names none. `orch-adopt.sh`, then fill §4 *with* Steven — never guessed. |
| `.beads/` | **Warranted** — multi-session, multi-phase. But `bd init` creates `.beads/ .agents/ .claude/ .codex/ .cursor/ .gitignore` **and appends a beads block to `CLAUDE.md` and `AGENTS.md`**. That list is the ask. |

Proposed §4 (irreversible actions) for `PROFILE.md`:

1. `gcloud run deploy personal-door` — publishes a public URL fronting finance data
2. Creating/publishing the Google OAuth client — an external-facing identity surface
3. Adding the connector or plugin in claude.ai — changes what every future session can reach
4. Any future write tool reaching `finance.*`/`gold.*` classification tables

### Phases

| # | Phase | Scope | Gate — Steven runs this | Done when |
|---|---|---|---|---|
| 1 | **Auth spike** | `door/main.py` with `door_whoami` only | ① create the Google OAuth client ② first `gcloud run deploy` ③ add the connector | `door_whoami` in Cowork returns his email, **and** a second Google account gets a hard refusal from the same URL |
| 2 | **State durability** | Firestore `client_storage` + Fernet + signing key | create the secrets, redeploy | Connector survives a cold start *and* a redeploy without re-adding |
| 3 | **Read tools** | `finance_native.py`, `saved_queries.py`, `tests/` | redeploy + **remove/re-add the connector** (tool list snapshots) | Validator tests green offline; the four canonical questions answer correctly in Cowork |
| 4 | **Skills + context** | `.claude/skills/personal/`, `finances/context/`, transport switch | — (repo edits only, fully reversible) | Same question answers identically in Claude Code and Cowork |
| 5 | **Plugin delivery** | `cowork/`, `sync-cowork-plugin.sh` | add the plugin in claude.ai | `/finances` auto-invokes in a fresh Cowork session from the plugin, not a paste |
| 6+ | Writes, then other domains | — | — | separate spec |

Phase 1 is the whole risk. Phases 3–5 are mechanical once identity holds.

### Verification, per phase

- Phase 1: two Google accounts, two outcomes. Screenshot both.
- Phase 3: run each canonical question **both ways** — `query.sh` locally and
  `run_finance_query` through the door — and diff the numbers. A door that
  disagrees with the laptop is a bug, not a rounding difference.
- Phase 5: a fresh Cowork session with no pasted context.

---

## 11. Open decisions for Steven

1. **Which Google account connects?** The door needs *identity only* — BigQuery
   access comes from the runtime service account, not from the human — so any of
   the three works if allowlisted. **Recommendation:
   `stevenharrisonjacobs@gmail.com`.** The Bobsled door enrolls
   `steven@bobsled.co` and the Snapfix door authenticates `steven@plumgrowth.ai`;
   putting the personal door on the personal account keeps all three on distinct
   identities, so no one session can reach across two of them. It also happens to
   be the account that owns the Tiller sheet.
2. **Which GCP project hosts the door?** `steven-tiller-finance-2026` keeps
   BigQuery access native with zero cross-project IAM. A dedicated project is
   cleaner if the door later reaches calendar/mail/weather.
   **Recommendation:** the finance project for MVP; revisit at Phase 7.
3. **Phase 0 go-ahead** — run `orch-adopt.sh` and `bd init`? `bd init` will
   append to `AGENTS.md`.
4. **The missing Advisor-review branch** — reconstruct `cash-flow-review.md`
   from the iCloud archive as part of Phase 4, or leave `/finances` at two
   branches for now?
