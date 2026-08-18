#!/usr/bin/env bash
# nightly-sync.sh — one nightly pipeline: rebuild the finance mirror, then run
# the finance agent over the fresh data.
#
# Invoked by launchd (com.stevenjacobs.finance-nightly.plist). Runs from the
# CANONICAL repo (not a Conductor worktree) so it always has a stable checkout
# and the .env with the finance + gcloud config.
#
#   1. deploy.sh   — deterministic full rebuild. Applies every committed rule,
#                    vendor-map row, and override against fresh sheet data. This
#                    is the only *write* the pipeline makes on its own.
#   2. validate.sh — sanity gate. If it fails, STOP before the agent runs, so a
#                    broken rebuild never gets "reviewed" as if it were real.
#   3. claude -p   — the finance agent runs /finances over the fresh data. By
#                    default (Steven's call, 2026-08-17) it runs AUTONOMOUSLY:
#                    classifies, applies clear-cut fixes, re-deploys, then reports.
#                    Set NIGHTLY_AGENT_AUTONOMOUS=0 to drop back to diagnose-only
#                    (no writes) — see the read-only-door rule in the finances skill.
#
# Auth, and why the environment below is explicit rather than inherited:
#
#   - deploy.sh needs gcloud authed WITH Drive access (it reads the Tiller sheet)
#     and needs bq + jq on PATH. launchd starts with essentially no PATH, so the
#     google-cloud-sdk bin is spelled out.
#   - the claude CLI stores its OAuth in the macOS Keychain, and the keychain
#     lookup fails without USER/LOGNAME set — measured: with only HOME+PATH it
#     reports "Not logged in · Please run /login". launchd does not set them.
#
# So both are pinned here AND in the plist. Verify a change with
# `launchctl start com.stevenjacobs.finance-nightly`, not just a shell run — an
# interactive shell hides exactly the variables that break under launchd.
#
# WHY A SERVICE ACCOUNT (NIGHTLY_SA_KEY): a *user* gcloud credential eventually
# demands an interactive reauth that gcloud cannot satisfy in a headless run —
# deploy.sh then dies with "Reauthentication failed. cannot prompt during
# non-interactive execution." A service-account key never reauths, so setting
# NIGHTLY_SA_KEY in .env to a downloaded key makes the job self-sufficient. Two
# deliberate choices in the activation block below:
#   * a THROWAWAY gcloud config dir (CLOUDSDK_CONFIG) so activating the SA never
#     rewrites Steven's real ~/.config/gcloud active account, which would silently
#     hijack his interactive gcloud after every nightly run;
#   * GOOGLE_APPLICATION_CREDENTIALS pointed at the same key so bq's query over
#     the Sheets-backed external table mints a token carrying the Drive scope.
#     A service account gets that scope with no consent step — the only gate is
#     that the Tiller sheet must be SHARED with the SA's email. That is the step
#     people miss; a missing share reads as an opaque BigQuery access error.
# If NIGHTLY_SA_KEY is unset the job falls back to the ambient user credential
# (old behaviour), so an interactive dev checkout without the key still runs.
set -uo pipefail

export PATH="/opt/homebrew/share/google-cloud-sdk/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export USER="${USER:-$(id -un)}"
export LOGNAME="${LOGNAME:-$USER}"

REPO="${FINANCE_REPO:-$HOME/conductor/repos/personal}"
CLAUDE_BIN="${CLAUDE_BIN:-/opt/homebrew/bin/claude}"
cd "$REPO" || { echo "nightly-sync: repo not found at $REPO" >&2; exit 1; }

# NIGHTLY_SA_KEY lives in .env (gitignored). Source just enough to read it; both
# deploy.sh and query.sh re-source .env fully via lib.sh, so this is only for the
# activation decision below.
if [[ -f "$REPO/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO/.env"
  set +a
fi

if [[ -n "${NIGHTLY_SA_KEY:-}" ]]; then
  [[ -f "$NIGHTLY_SA_KEY" ]] || {
    echo "nightly-sync: NIGHTLY_SA_KEY is set but no key file at $NIGHTLY_SA_KEY" >&2
    exit 1
  }
  SA_CONFIG_DIR="$(mktemp -d)"
  trap 'rm -rf "$SA_CONFIG_DIR"' EXIT
  export CLOUDSDK_CONFIG="$SA_CONFIG_DIR"
  export GOOGLE_APPLICATION_CREDENTIALS="$NIGHTLY_SA_KEY"
  if ! gcloud auth activate-service-account --key-file="$NIGHTLY_SA_KEY" >/dev/null 2>&1; then
    echo "nightly-sync: failed to activate service account from $NIGHTLY_SA_KEY" >&2
    exit 1
  fi
fi

STAMP="$(date +%Y-%m-%d)"
LOG_DIR="$REPO/.context/nightly"
mkdir -p "$LOG_DIR"
REPORT="$LOG_DIR/sync-$STAMP.md"

log() { echo "$@" | tee -a "$REPORT"; }

# deploy.sh echoes every statement it runs, which is ~100KB of SQL. Piping that
# into the report buried the part a human actually reads. Each step now writes
# its own log and the report carries a one-line verdict — plus the tail of the
# log when something fails, so a failure is still legible without opening it.
DEPLOY_LOG="$LOG_DIR/deploy-$STAMP.log"
VALIDATE_LOG="$LOG_DIR/validate-$STAMP.log"

fail_with_tail() { # fail_with_tail LOGFILE MESSAGE
  log ""
  log "**$2**"
  log ""
  log '```'
  tail -25 "$1" >> "$REPORT"
  log '```'
  log ""
  log "Full output: $1"
}

: > "$REPORT"
log "# Nightly finance sync — $STAMP"
log ""
log "## 1. Rebuild (deploy.sh)"
if ./scripts/deploy.sh >"$DEPLOY_LOG" 2>&1; then
  log "OK — rebuilt. Full output: $DEPLOY_LOG"
else
  fail_with_tail "$DEPLOY_LOG" "DEPLOY FAILED — aborting before validate/agent."
  exit 1
fi

log ""
log "## 2. Validate (validate.sh)"
if ./scripts/validate.sh >"$VALIDATE_LOG" 2>&1; then
  # The counts are small and genuinely worth reading, so they stay inline. bq
  # writes its progress spinner with carriage returns, so the "Waiting on bqjob"
  # text is not at the start of a line and an anchored pattern misses it.
  tr '\r' '\n' < "$VALIDATE_LOG" \
    | grep -v 'Waiting on bqjob' | grep -vE '^\+' | grep -v '^[[:space:]]*$' >> "$REPORT"
else
  fail_with_tail "$VALIDATE_LOG" "VALIDATION FAILED — aborting before agent."
  exit 1
fi

log ""
log "## 3. Agent review"

# A headless agent has nobody to approve a tool call, so permissions have to be
# settled up front or it stalls having done nothing.
#
#   autonomous    -> bypassPermissions. It genuinely needs to write (add-rule.sh,
#                    add-override.sh, deploy.sh), so the guardrail is the mandate
#                    below plus the fact that every write is logged and revertible.
#   diagnose-only -> an explicit allowlist, so "no writes" is ENFORCED by the
#                    harness rather than trusted to the prompt. query.sh is
#                    read-only; the write scripts are simply not reachable.
if [[ "${NIGHTLY_AGENT_AUTONOMOUS:-1}" == "1" ]]; then
  MANDATE="Then work the classification review queue
(queries/vendor-category-candidates.sql) for a WHILE, not to exhaustion —
references/vendor-mapping.md is the procedure and its rulings table is already
decided, so apply those without asking. Respect suggested_action literally:
alias variants instead of re-mapping them, promote recurring copilot rows, verify
SUSPECT rows before trusting them, and STOP on small one-offs. Never map a
one-off or a mixed-basket merchant — a wrong mapping applies confidently to every
future transaction and nothing flags it. Re-deploy when you have written
something, and report the tiller share of expense spend from
queries/classification-sources.sql before and after so the trend is visible."
  PERM=(--permission-mode bypassPermissions)
else
  MANDATE="Apply NO classification writes tonight. Diagnose only and list the
exact fixes a human should apply in a Claude Code session."
  PERM=(--allowed-tools "Bash(./scripts/query.sh:*)" Read Grep Glob Write)
fi

PROMPT="You are the nightly finance steward, running headless with no human to
ask. The mirror was just rebuilt and validated. Follow the finances skill
(.claude/skills/finances). Run the update-database diagnosis: mirror-level health
FIRST (if nothing has arrived on ANY account for days the mirror itself is broken
and nothing else below means anything), then per-account feed freshness judged
against other accounts, the silent-vendor check, and the flagged queues
(gold.transaction_flow_review, gold.transaction_anomaly_review_queue). Then write
a short, plain report: what you changed, what needs Steven, what you deliberately
left alone. ${MANDATE} Keep raw merchant/amount detail in .context only — never
commit it."

# The prompt goes in on STDIN, not as a positional argument. --allowed-tools is
# variadic (<tools...>), so a trailing prompt is swallowed as one more tool name
# and claude exits with "Input must be provided either through stdin or as a
# prompt argument". Measured 2026-08-17: this broke diagnose-only mode while
# autonomous mode worked, because --permission-mode takes exactly one value.
printf '%s' "$PROMPT" | "$CLAUDE_BIN" -p "${PERM[@]}" >>"$REPORT" 2>&1
AGENT_RC=$?

log ""
if [[ $AGENT_RC -ne 0 ]]; then
  log "**AGENT STEP FAILED (exit $AGENT_RC)** — rebuild+validate still succeeded."
fi
log "Done — report at $REPORT"
exit $AGENT_RC
