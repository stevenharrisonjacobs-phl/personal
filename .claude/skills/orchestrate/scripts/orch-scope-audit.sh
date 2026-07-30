#!/usr/bin/env bash
# orch-scope-audit.sh — enforce "one writer per path-scope" from git, not from claims.
#
# Read-only with respect to git history: never commits, pushes, checks out, or
# resets. It runs `git fetch origin` once to refresh remote-tracking refs.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: orch-scope-audit.sh <program-slug> [lane-id]

For each lane (or just <lane-id>), diffs origin/main...origin/<branch> and reports:

  OUT OF SCOPE   changed files matching NO glob in that lane's `owns`
  FORBIDDEN      changed files matching any glob in that lane's `forbids`
  in scope       count of changed files that are legitimately owned

Globs are matched by git itself using `:(glob)` magic pathspecs, so `*` and `**`
mean what they mean in .gitignore-style globs (`agent_knowledge/deal/**` matches
everything under that directory). Renames are NOT collapsed — a rename shows both
the old path and the new one, so moving a file out of scope is visible.

Shared aggregators (CLAUDE.md, README.md, CI workflows, cross-domain packages)
belong to the orchestrator and are resolved exactly once, centrally. A lane that
touched one has a finding here, not a merge conflict later.

Exit codes:
  0   every audited lane is clean
  1   at least one lane has out-of-scope or forbidden changes  (use as a gate)
  2   operational error (bad args, missing registry, no origin/main, no jq)

Options:
  -h, --help   show this help
EOF
}

die() { printf 'orch-scope-audit: %s\n' "$*" >&2; exit 2; }

case "${1-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage >&2; die "expected <program-slug> [lane-id], got $# argument(s)"; }

SLUG="$1"
ONLY_LANE="${2-}"

command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH. Install it (brew install jq) and re-run."

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$REPO_ROOT"

PROG_DIR="orchestration/$SLUG"
LANES_JSON="$PROG_DIR/lanes.json"
[ -f "$LANES_JSON" ] || die "no such lane registry: $LANES_JSON (run orch-init.sh $SLUG first)"
jq -e . "$LANES_JSON" >/dev/null 2>&1 || die "$LANES_JSON is not valid JSON"

TMPDIR_="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_"; }
trap cleanup EXIT

git fetch origin --quiet >/dev/null 2>&1 || printf 'orch-scope-audit: warning: git fetch origin failed (offline?); auditing against possibly stale remote-tracking refs.\n' >&2

git show-ref --verify --quiet refs/remotes/origin/main || die "origin/main not found — cannot compute a scope diff"

LANE_TSV="$TMPDIR_/lanes.tsv"
jq -r '.lanes[]? | [(.id // "?"), (.name // ""), (.branch // "")] | @tsv' "$LANES_JSON" >"$LANE_TSV"

if [ -n "$ONLY_LANE" ]; then
  FILTERED="$TMPDIR_/lanes.filtered"
  awk -F'\t' -v want="$ONLY_LANE" '$1 == want' "$LANE_TSV" >"$FILTERED"
  [ -s "$FILTERED" ] || die "lane '$ONLY_LANE' is not declared in $LANES_JSON"
  LANE_TSV="$FILTERED"
fi

printf '\nScope audit — program %s%s\n' "$SLUG" "$([ -n "$ONLY_LANE" ] && printf ', lane %s' "$ONLY_LANE")"
printf 'Base: origin/main @ %s\n' "$(git rev-parse --short origin/main)"

VIOLATIONS=0
AUDITED=0
SKIPPED=0

while IFS="$(printf '\t')" read -r ID NAME BRANCH; do
  [ -n "${ID:-}" ] || continue

  printf '\nLane %s — %s\n' "$ID" "${NAME:-<unnamed>}"

  if [ -z "${BRANCH:-}" ]; then
    printf '  - no branch declared; skipped.\n'
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  if ! git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    printf '  - branch origin/%s does not exist yet; skipped (nothing to audit).\n' "$BRANCH"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  AUDITED=$((AUDITED + 1))
  RANGE="origin/main...origin/$BRANCH"
  printf '  branch: origin/%s   range: %s\n' "$BRANCH" "$RANGE"

  CHANGED="$TMPDIR_/changed.$ID"
  OWNED="$TMPDIR_/owned.$ID"
  FORBID="$TMPDIR_/forbid.$ID"
  ERRF="$TMPDIR_/err.$ID"
  : >"$OWNED"; : >"$FORBID"; : >"$ERRF"

  git diff --name-only --no-renames "$RANGE" 2>/dev/null | sort -u >"$CHANGED" || true
  N_CHANGED="$(wc -l <"$CHANGED" | tr -d ' ')"

  if [ "$N_CHANGED" -eq 0 ]; then
    printf '  no changes vs origin/main.\n'
    continue
  fi

  # union of per-glob matches for `owns`
  OWNS_TSV="$TMPDIR_/owns.$ID"
  jq -r --arg id "$ID" '.lanes[] | select((.id // "?") == $id) | (.owns // [])[]' "$LANES_JSON" >"$OWNS_TSV"
  N_OWNS="$(wc -l <"$OWNS_TSV" | tr -d ' ')"
  while IFS= read -r g; do
    [ -n "${g:-}" ] || continue
    if ! git diff --name-only --no-renames "$RANGE" -- ":(glob)$g" >>"$OWNED" 2>"$ERRF"; then
      printf '  ! unusable owns glob %s — %s\n' "$g" "$(tr '\n' ' ' <"$ERRF")"
    fi
  done <"$OWNS_TSV"
  sort -u -o "$OWNED" "$OWNED"

  # union of per-glob matches for `forbids`
  FORBIDS_TSV="$TMPDIR_/forbids.$ID"
  jq -r --arg id "$ID" '.lanes[] | select((.id // "?") == $id) | (.forbids // [])[]' "$LANES_JSON" >"$FORBIDS_TSV"
  while IFS= read -r g; do
    [ -n "${g:-}" ] || continue
    if ! git diff --name-only --no-renames "$RANGE" -- ":(glob)$g" >>"$FORBID" 2>"$ERRF"; then
      printf '  ! unusable forbids glob %s — %s\n' "$g" "$(tr '\n' ' ' <"$ERRF")"
    fi
  done <"$FORBIDS_TSV"
  sort -u -o "$FORBID" "$FORBID"

  OUT="$TMPDIR_/out.$ID"
  comm -23 "$CHANGED" "$OWNED" >"$OUT" || true

  N_OUT="$(wc -l <"$OUT" | tr -d ' ')"
  N_FORBID="$(wc -l <"$FORBID" | tr -d ' ')"
  N_IN=$((N_CHANGED - N_OUT))

  if [ "$N_OWNS" -eq 0 ]; then
    printf '  ! lane declares no `owns` globs — every changed file is out of scope by definition.\n'
  fi

  printf '  in scope:      %s of %s changed file(s)\n' "$N_IN" "$N_CHANGED"

  if [ "$N_OUT" -gt 0 ]; then
    printf '  OUT OF SCOPE (%s) — matches no `owns` glob:\n' "$N_OUT"
    sed 's/^/    /' "$OUT"
    VIOLATIONS=$((VIOLATIONS + 1))
  fi

  if [ "$N_FORBID" -gt 0 ]; then
    printf '  FORBIDDEN (%s) — matches a `forbids` glob:\n' "$N_FORBID"
    sed 's/^/    /' "$FORBID"
    if [ "$N_OUT" -eq 0 ]; then
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  fi

  if [ "$N_OUT" -eq 0 ] && [ "$N_FORBID" -eq 0 ]; then
    printf '  clean.\n'
  fi
done <"$LANE_TSV"

printf '\n%s lane(s) audited, %s skipped, %s with findings.\n' "$AUDITED" "$SKIPPED" "$VIOLATIONS"

if [ "$VIOLATIONS" -gt 0 ]; then
  printf 'FAIL — single-writer boundary violated. Resolve shared-file changes centrally,\n'
  printf 'in the orchestrator, exactly once; lanes request them in their handoff.\n\n'
  exit 1
fi

printf 'PASS — every audited lane stayed inside its declared path-scope.\n\n'
