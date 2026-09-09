# Cloud check-in runbook

The 6am spend check-in runs as a claude.ai/code **routine** (scheduled cloud
session) that is a client of the Personal Door. This runbook is the operating
manual: credentials, schedules, provisioning commands, probes, triage, and
rotation. Plan of record:
`admin/berlin docs/plans/2026-09-08-1851-feat-cloud-routine-spend-checkin-plan.md`.

## Schedule map (what fires when, on what hardware)

| When (ET) | What | Where | Identity |
|---|---|---|---|
| hourly | Tiller mirror rebuild (`sql/refresh.sql`, rebuilds `gold.transactions`) | BigQuery scheduled query (server-side) | BQ transfer service |
| 3:00 | finance nightly (rebuild → validate → agent) — unchanged | laptop launchd | ambient gcloud |
| ~6:00 | `spend-checkin-morning` routine: generate + land report | cloud | `checkin-routine` |
| 6:30 | laptop fallback generator (burn-in only; unload at cutover) | laptop launchd | ambient gcloud |
| ~7:05 | `spend-checkin-watchdog` routine: no success row → failed row | cloud | `checkin-watchdog` |

Timezone invariant: both routines' `next_run_at` must correspond to the times
above in **America/New_York**. Verify at creation and after every DST
transition (routine cron is local-wall-clock per platform docs; the today-guard
and window dial are ET-anchored regardless).

## Credential manifest

Every credential visible in the cloud environment MUST appear here. The U6/R18
negative probe is an inventory diff against this table — anything unlisted
fails the probe.

| Credential | Scope | Storage | Rotation / lifecycle | Owner |
|---|---|---|---|---|
| `PERSONAL_DOOR_TOKEN` (checkin-routine) | door grants: report tools always; classification 06:45–23:00 ET; enumerated reads | masked API credential for the door host (preferred) or env var (fallback — record here if taken) | first-party lifecycle below | Steven |
| watchdog door token | door grants: `record_checkin_failed` + existence-check read only | claude.ai environment of the watchdog routine (masked preferred) | first-party lifecycle below | Steven |
| smoke door token | door grants: report tools only | held locally by Steven; used for U7 smokes / U8 drills | first-party lifecycle below | Steven |
| `SNAPFIX_SA_B64` | snapfix-agents: `jobUser` + `resourceViewer` (job costs; NOTE: `resourceViewer` exposes full SQL text of all project jobs — accepted, wrapper-tool deferred) | plain env var (base64 JSON; decoded in-process, never on disk) | 90-day key rotation | Steven |
| `MERCURY_API_TOKEN` | Mercury **read-only** (no IP allowlist needed) | masked API credential preferred | Mercury auto-deletes after 45 idle days (daily use keeps it alive); revoke+remint on suspicion | Steven |
| `VANTAGE_API_TOKEN` | Vantage read | masked preferred; env fallback for the MCP handshake if masking fails (record) | annual review; revoke on suspicion | Steven |
| `LANGSMITH_API_KEY` | LangSmith read (fresh least-scope key, not the snapfix sibling's) | env var (SDK needs in-process key) unless masking proves workable | annual review | Steven |
| `APIFY_API_TOKEN` | Apify read (least scope) | masked preferred | annual review | Steven |

**First-party door-token lifecycle:** tokens are ≥32 random bytes; the door
stores SHA-256 digests only. Max age 180 days. On suspected leak: remove the
digest from door env (redeploy candidate → probe → promote), mint a
replacement, update the environment's masked credential, re-run the U8 dial
probes. Dual-token rollover: add the new digest alongside the old, switch the
client, then remove the old digest.

## One-time provisioning (Steven-executed)

### 1. Door runtime SA — table-level write grants (run under your gcloud auth)

```bash
PROJ=steven-tiller-finance-2026
SA="serviceAccount:personal-door-runtime@${PROJ}.iam.gserviceaccount.com"
for T in \
  "finance.checkin_reports" "finance.door_audit_log" \
  "finance.transaction_overrides" "finance.classification_rules" \
  "gold.vendor_category_map" "gold.vendor_aliases" "gold.vendor_rules" \
  "gold.transaction_vendor_overrides" "gold.transaction_flow_overrides"; do
  bq add-iam-policy-binding --member="$SA" --role=roles/bigquery.dataEditor \
    "${PROJ}:${T/./.}" ; done
```

(Note: `finance.door_audit_log` must exist first — `./scripts/deploy.sh`
creates it via `sql/door.sql`.)

### 2. Snapfix read SA (job costs)

```bash
SPROJ=snapfix-agents
gcloud iam service-accounts create checkin-costs-read \
  --project="$SPROJ" --display-name="spend check-in job-cost reader"
SAEMAIL="checkin-costs-read@${SPROJ}.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$SPROJ" \
  --member="serviceAccount:$SAEMAIL" --role=roles/bigquery.jobUser
gcloud projects add-iam-policy-binding "$SPROJ" \
  --member="serviceAccount:$SAEMAIL" --role=roles/bigquery.resourceViewer
gcloud iam service-accounts keys create /tmp/checkin-costs-read.json \
  --iam-account="$SAEMAIL"
base64 -i /tmp/checkin-costs-read.json | pbcopy   # → SNAPFIX_SA_B64, then
rm /tmp/checkin-costs-read.json                    # delete the key file
```

### 3. Door machine tokens

Minted during the door deploy (`scripts/deploy-door.sh` secrets stage) — three
tokens, three digests in door env, grants JSON per `door/.env.example`.

### 4. Cloud environment (claude.ai/code → Environments)

- Repo: `stevenharrisonjacobs-phl/personal`; setup script: `scripts/cloud-setup.sh`.
- Network: **Trusted** (add custom hosts only for sources whose masked route fails).
- Env vars: `SNAPFIX_SA_B64`, `LANGSMITH_API_KEY` (if not masked), per-source
  `*_AUTH=proxy` signals for every masked source.
- API credentials (masked): door host + `api.mercury.com` + `api.apify.com`
  (+ `mcp.vantage.sh` / `api.smith.langchain.com` if the injection composes —
  record the observed mechanism per source here after U6 verification).

## Consume triage (five states)

1. **Fresh success** — read it.
2. **DEGRADED-stamped** — a named source was null; totals for that source are
   missing, everything else stands. Three consecutive mornings → Notes escalates.
3. **STALE-stamped** — mirror rebuild >6h old at generation; personal numbers
   may lag. Check the hourly scheduled query in BigQuery.
4. **Failed row** — read the reason. Precedence: a failed row never masks a
   later success (consume reads the latest success; late success supersedes).
5. **No row at all** — generator and watchdog both missed. Check
   `RemoteTrigger list_runs` for both routines, then `get_run_log` on the last
   run; platform caps and suspensions leave no row.

## Probe & re-verification cadence (monthly, and after any platform change)

- Diff both routines' `get` config against the recorded intent (tools,
  `mcp_connections` empty, `persist_session`, cron/timezone).
- Re-run the U8 dial probes: routine token classification write inside the
  autonomous window → refused; watchdog token classification → refused;
  stranger token → unauthorized; bogus-token candidate probe on next deploy.
- Enumerate account surfaces carrying the Personal Door connector; it must be
  attached to **no autonomous surface** (routines' `mcp_connections`).
- Check door-token ages against the lifecycle above; check SA key age (90d).

## Burn-in / cutover checklist (U8)

- [ ] Laptop generator offset to 6:30 (plist committed; `launchctl unload/load` to apply)
- [ ] Timezone read-back for both routines
- [ ] Dial probes green (all identities)
- [ ] Injection red-team: autonomous leg + open-window persisted-session leg
- [ ] Mercury/report parity gate over a representative window (MCP-vs-REST, local-vs-cloud)
- [ ] ≥3 consecutive green *scheduled* mornings (smokes excluded), one lid-closed
- [ ] Cold-session gate: ≥2/3 mornings warm at reading time + one warm reclassify drill
- [ ] Watchdog drills: suppressed morning + simulated door-read error
- [ ] Audit-join attribution check (cloud vs laptop writes)
- [ ] Cutover: `launchctl unload ~/Library/LaunchAgents/com.stevenjacobs.spend-checkin.plist` and remove the plist from LaunchAgents (repo copy stays for history)

## Known residuals (accepted, documented)

- Platform-wide outage takes generator and watchdog down together → no-row
  morning; consume staleness is the catch. No notification channel exists yet
  (deferred) — absence detection reaches Steven when he looks.
- Generator and watchdog share the environment and the door (shared-fate).
- `dataEditor` technically permits UPDATE/DELETE on granted tables —
  append-only is door-tool discipline; BigQuery time travel is recovery; the
  monotone-history check watches it.
- Session transcripts and raw `.context/checkin` pulls hold row-level data on
  platform infrastructure for the session's life — accepted retention surface.
- `.mcp.json` also loads in local sessions where `PERSONAL_DOOR_TOKEN` is
  unset — the door connection fails quietly there; expected noise.
