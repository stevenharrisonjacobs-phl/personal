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
# Auth note: both steps need credentials that live on THIS machine — gcloud must
# be authed as steven@plumgrowth.ai with Drive access (deploy.sh), and the claude
# CLI must be logged in. launchd runs with a bare environment, so test this
# script by hand first (`bash scripts/nightly-sync.sh`) before loading the plist.
set -uo pipefail

REPO="${FINANCE_REPO:-$HOME/conductor/repos/personal}"
CLAUDE_BIN="${CLAUDE_BIN:-/opt/homebrew/bin/claude}"
cd "$REPO" || { echo "nightly-sync: repo not found at $REPO" >&2; exit 1; }

STAMP="$(date +%Y-%m-%d)"
LOG_DIR="$REPO/.context/nightly"
mkdir -p "$LOG_DIR"
REPORT="$LOG_DIR/sync-$STAMP.md"

log() { echo "$@" | tee -a "$REPORT"; }

: > "$REPORT"
log "# Nightly finance sync — $STAMP"
log ""
log "## 1. Rebuild (deploy.sh)"
if ! ./scripts/deploy.sh >>"$REPORT" 2>&1; then
  log ""
  log "**DEPLOY FAILED — aborting before validate/agent.**"
  exit 1
fi

log ""
log "## 2. Validate (validate.sh)"
if ! ./scripts/validate.sh >>"$REPORT" 2>&1; then
  log ""
  log "**VALIDATION FAILED — aborting before agent.**"
  exit 1
fi

log ""
log "## 3. Agent review"

if [[ "${NIGHTLY_AGENT_AUTONOMOUS:-1}" == "1" ]]; then
  MANDATE="You MAY apply clear-cut classification fixes (rules, overrides) and
re-deploy. Log every write. Leave anything ambiguous for a human and flag it."
else
  MANDATE="Apply NO classification writes tonight. Diagnose only and list the
exact fixes a human should apply in a Claude Code session."
fi

"$CLAUDE_BIN" -p "You are the nightly finance steward, running headless with no
human to ask. The mirror was just rebuilt and validated. Run the /finances
update DIAGNOSIS: feed freshness, the stale-feed and silent-vendor checks, and
the flagged review queues (gold.transaction_flow_review,
gold.transaction_anomaly_review_queue). Write a short, plain report of what needs
attention. ${MANDATE} Keep raw merchant/amount detail in .context only — never
commit it." >>"$REPORT" 2>&1

log ""
log "Done — report at $REPORT"
