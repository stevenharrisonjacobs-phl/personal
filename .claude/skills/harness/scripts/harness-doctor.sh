#!/usr/bin/env bash
# harness-doctor.sh — report this repo's harness state in two lines.
#
# Runs from the SessionStart hook in EVERY workspace, so it obeys three rules:
# it is fast, it never fails the session, and it stays quiet when there is
# nothing to say. Read-only: it inspects and reports, and changes nothing.
#
# Exit code is always 0. A broken doctor must never block a session.
#
# Usage: harness-doctor.sh [--verbose]
#   default    two compact lines for hook injection
#   --verbose  a human-readable report with the remedy for each gap

set +e  # a failing probe reports "unknown", it does not abort

CURRENT_SCHEMA=1   # bump when templates/PROFILE.md gains or renames a section

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$ROOT" ]; then
  [ "$VERBOSE" -eq 1 ] && echo "harness: not inside a git repository — nothing to instantiate."
  exit 0
fi
cd "$ROOT" 2>/dev/null || exit 0

REPO=$(basename "$ROOT")

# --- context file -------------------------------------------------------------
# `bd init` writes its own CLAUDE.md/AGENTS.md, so presence alone is not proof of
# repo context. Strip the beads block; if nothing but whitespace is left, the
# file is a beads stub and the repo still needs a real /init.
# Presence only — deliberately not a quality judgement. `bd init` writes its own
# CLAUDE.md and AGENTS.md, so a context file may be generated rather than real,
# but neither line count nor placeholder text separates the two reliably (a real
# AGENTS.md here is 52 lines; beads' generated one is 55). Reporting presence and
# letting a human judge beats a confident wrong verdict. The caveat lives in
# SKILL.md, where it is read.
CONTEXT=""
for f in CLAUDE.md AGENTS.md; do
  [ -f "$f" ] && { CONTEXT="$f"; break; }
done

# --- profile + schema ---------------------------------------------------------
PROFILE=""
SCHEMA=""
STALE=""
if [ -f orchestration/PROFILE.md ]; then
  PROFILE="yes"
  SCHEMA=$(grep -m1 -oE 'Harness schema:\*\* *[0-9]+' orchestration/PROFILE.md 2>/dev/null | grep -oE '[0-9]+$')
  [ -z "$SCHEMA" ] && SCHEMA=0
  # "Last verified: `YYYY-MM-DD`" — flag anything older than 90 days.
  VERIFIED=$(grep -m1 -oE 'Last verified:\*\* *.?[0-9]{4}-[0-9]{2}-[0-9]{2}' orchestration/PROFILE.md 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
  if [ -n "$VERIFIED" ]; then
    V_EPOCH=$(date -j -f "%Y-%m-%d" "$VERIFIED" "+%s" 2>/dev/null || date -d "$VERIFIED" "+%s" 2>/dev/null)
    NOW_EPOCH=$(date "+%s")
    if [ -n "$V_EPOCH" ] && [ $(( (NOW_EPOCH - V_EPOCH) / 86400 )) -gt 90 ]; then
      STALE="$VERIFIED"
    fi
  fi
fi

# --- task graph ---------------------------------------------------------------
BEADS=""
[ -d .beads ] && BEADS="yes"

# --- compact form (hook injection) -------------------------------------------
if [ "$VERBOSE" -eq 0 ]; then
  MISSING=""
  [ -z "$CONTEXT" ] && MISSING="${MISSING}context "
  [ -z "$PROFILE" ] && MISSING="${MISSING}profile "
  [ -z "$BEADS" ]   && MISSING="${MISSING}tasks "
  DRIFT=""
  [ -n "$PROFILE" ] && [ "$SCHEMA" -lt "$CURRENT_SCHEMA" ] 2>/dev/null && DRIFT="profile schema $SCHEMA<$CURRENT_SCHEMA "
  [ -n "$STALE" ] && DRIFT="${DRIFT}profile last verified $STALE "

  if [ -n "$MISSING" ] || [ -n "$DRIFT" ]; then
    printf 'harness[%s]: missing: %s· drift: %s— run /harness to fix.\n' \
      "$REPO" "${MISSING:-none }" "${DRIFT:-none }"
  else
    printf 'harness[%s]: instantiated (context, profile, task graph all present).\n' "$REPO"
  fi
  printf 'Before your first action, state the triage verdict in one line — reversibility, then write-scopes. See ~/.claude/CLAUDE.md.\n'
  exit 0
fi

# --- verbose form -------------------------------------------------------------
echo "Harness state — $REPO"
echo
if [ -n "$CONTEXT" ]; then
  echo "  context file      $CONTEXT"
  grep -q "BEGIN BEADS INTEGRATION" "$CONTEXT" 2>/dev/null && \
    echo "                    (contains a beads block — if that is ALL it contains, /init is still owed)"
else
  echo "  context file      MISSING     → run /init"
fi

if [ -n "$PROFILE" ]; then
  if [ "$SCHEMA" -lt "$CURRENT_SCHEMA" ] 2>/dev/null; then
    echo "  orchestration     PROFILE.md (schema $SCHEMA, current $CURRENT_SCHEMA)  → /harness can patch the gap"
  else
    echo "  orchestration     PROFILE.md (schema $SCHEMA)"
  fi
  [ -n "$STALE" ] && echo "                    last verified $STALE — over 90 days; re-measure before relying on it"
else
  echo "  orchestration     MISSING     → orch-adopt.sh (only needed if this repo has irreversible actions)"
fi

if [ -n "$BEADS" ]; then echo "  task graph        .beads/"
else                     echo "  task graph        MISSING     → bd init (only needed for multi-step work)"; fi
echo
echo "Not every repo needs all three. A repo with nothing irreversible and no"
echo "multi-step work needs only a context file."
exit 0
