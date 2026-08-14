#!/usr/bin/env bash
# orch-adopt.sh — scaffold orchestration/PROFILE.md for a repo adopting /orchestrate.
#
# Creates the profile from the skill's template and probes the repo for starting
# answers (build/test/lint commands, CI presence, branch model, likely shared
# aggregators by churn). It fills in NOTHING authoritative — every probe result
# is written as a commented hint. The profile is a set of claims someone will act
# on, so a human confirms each one.
#
# Usage:  bash <skill-dir>/scripts/orch-adopt.sh [--force]
set -euo pipefail

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1
[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

command -v git >/dev/null 2>&1 || { echo "git is required." >&2; exit 2; }
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Not inside a git repository." >&2; exit 2; }
cd "$ROOT"

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEMPLATE="$SKILL_DIR/templates/PROFILE.md"
[ -f "$TEMPLATE" ] || { echo "Template missing: $TEMPLATE" >&2; exit 2; }

DEST="orchestration/PROFILE.md"
if [ -f "$DEST" ] && [ "$FORCE" -eq 0 ]; then
  echo "$DEST already exists. Re-verify it rather than regenerating (--force to overwrite)."
  exit 1
fi

mkdir -p orchestration
cp "$TEMPLATE" "$DEST"

REPO=$(git config --get remote.origin.url 2>/dev/null | sed -E 's#.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#' || echo "<org/repo>")
DEFAULT=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || echo main)
TODAY=$(date +%Y-%m-%d)

# --- probes: hints only, never authoritative ---------------------------------
probe() { printf '%s\n' "$1" >> "$DEST"; }

{
  echo ""
  echo "---"
  echo ""
  echo "<!-- ============================================================"
  echo "     PROBE RESULTS — generated $TODAY by orch-adopt.sh."
  echo "     These are HINTS, not answers. Confirm each with the approver,"
  echo "     fold the real ones into the sections above, then DELETE this block."
  echo "     ============================================================"
  echo ""
  echo "     repo:            $REPO"
  echo "     default branch:  $DEFAULT"
  echo ""
} >> "$DEST"

probe "     --- candidate gate commands ---"
if [ -f package.json ] && command -v jq >/dev/null 2>&1; then
  jq -r '.scripts // {} | to_entries[] | "     package.json: \(.key) → \(.value)"' package.json 2>/dev/null >> "$DEST" || true
elif [ -f package.json ]; then
  probe "     package.json present (install jq for a script listing)"
fi
[ -f Makefile ]        && probe "     Makefile present — check its targets"
[ -f pyproject.toml ]  && probe "     pyproject.toml present — check [tool.*] test/lint config"
[ -f Cargo.toml ]      && probe "     Cargo.toml present — cargo test / clippy"
[ -f go.mod ]          && probe "     go.mod present — go test ./... / go vet"
probe ""

probe "     --- what runs automatically ---"
if [ -d .github/workflows ]; then
  find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) \
    | sed 's|^|     workflow: |' >> "$DEST"
else
  probe "     NO .github/workflows — if nothing else runs automatically, say so in"
  probe "     profile §1. The consequence is explicit: the orchestrator IS the CI."
fi
HOOKS=$(git config --get core.hooksPath 2>/dev/null || true)
[ -n "$HOOKS" ] && probe "     core.hooksPath = $HOOKS"
[ -d .husky ]   && probe "     .husky/ present"
probe ""

probe "     --- branch model ---"
git branch -r --format='%(refname:short)' 2>/dev/null | grep -v HEAD | sed 's|^|     remote branch: |' | head -8 >> "$DEST" || true
probe "     (more than one long-lived branch usually means an extra ladder rung)"
probe ""

probe "     --- likely shared aggregators (top churn, last 100 commits) ---"
git log --pretty=format: --name-only -100 2>/dev/null \
  | sed '/^$/d' | sort | uniq -c | sort -rn | head -12 \
  | awk '{printf "     %5s  %s\n", $1, $2}' >> "$DEST" || true
probe "     (high churn = many lanes will want it = orchestrator-owned)"
probe ""

probe "     --- generated / large files that merge badly ---"
git ls-files 2>/dev/null | grep -iE '\.(lock|gen\.[a-z]+|snap)$|lock\.json$|generated' | head -8 | sed 's|^|     |' >> "$DEST" || true
probe ""
probe "     -->"

cat <<EOF

Created $DEST

Next:
  1. Fill sections 1-6 BY MEASURING — run the commands, read the config, hit the
     real system. Every line is a claim someone will act on.
  2. Section 4 (irreversible actions) is the one to get right, and it is a
     conversation with the approver, not a guess. It names what cannot be undone.
  3. Delete the PROBE RESULTS block once you have folded in the real answers.
  4. Commit it. The profile must survive the worktree.

Then: bash $SKILL_DIR/scripts/orch-init.sh <program-slug>
EOF
