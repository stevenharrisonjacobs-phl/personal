#!/usr/bin/env bash
# orch-status.sh — recompute a program's state from git, never from claims.
#
# Read-only with respect to git history: never commits, pushes, checks out, or
# resets. It runs `git fetch origin` once to refresh remote-tracking refs.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: orch-status.sh <program-slug>

Reads orchestration/<program-slug>/lanes.json, fetches origin once, and prints one
row per lane recomputed from git:

  lane id + name + kind
  ORIGIN    does origin/<branch> exist?
  A/B       ahead/behind origin/main (git rev-list --left-right --count)
  HANDOFF   does the lane's handoff path exist in the origin/<branch> tree?
  VERDICT   SAFE / NOT-SAFE / MIXED / -   (grepped from the handoff blob)
  MERGED    is origin/<branch> an ancestor of origin/main?

Then a summary, then any escalation without a matching decision (open
escalations), matched loosely on the <date>-<topic> portion of the filename and
searched both in the working tree and in each lane branch's tree.

Recorded booleans are assertions. This recomputes them.

Options:
  -h, --help   show this help
EOF
}

die() { printf 'orch-status: %s\n' "$*" >&2; exit 1; }

case "${1-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -eq 1 ] || { usage >&2; die "expected exactly one argument (<program-slug>), got $#"; }

SLUG="$1"

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

git fetch origin --quiet >/dev/null 2>&1 || printf 'orch-status: warning: git fetch origin failed (offline?); reporting against possibly stale remote-tracking refs.\n' >&2

HAVE_MAIN=no
git show-ref --verify --quiet refs/remotes/origin/main && HAVE_MAIN=yes
[ "$HAVE_MAIN" = no ] && printf 'orch-status: warning: origin/main not found; ahead/behind and merged columns will show "-".\n' >&2

PROGRAM="$(jq -r '.program // ""' "$LANES_JSON")"
STANDING="$(jq -r 'if .standing then "standing" else "program" end' "$LANES_JSON")"
BASE="$(jq -r '.base // ""' "$LANES_JSON")"
ORCH_BRANCH="$(jq -r '.orchestrator_branch // ""' "$LANES_JSON")"

printf '\n%s  (%s)\n' "${PROGRAM:-$SLUG}" "$STANDING"
printf 'orchestrator branch: %s\n' "${ORCH_BRANCH:-<unset>}"
printf 'base:                %s' "${BASE:-<unset>}"
if [ -n "$BASE" ] && [ "$HAVE_MAIN" = yes ]; then
  if git merge-base --is-ancestor "$BASE" origin/main 2>/dev/null; then
    printf ' (contained in origin/main)'
  else
    printf ' (NOT an ancestor of origin/main — base drifted or sha is unknown)'
  fi
fi
printf '\n\n'

LANE_TSV="$TMPDIR_/lanes.tsv"
jq -r '.lanes[]? | [(.id // "?"), (.name // ""), (.kind // ""), (.branch // ""), (.handoff // "")] | @tsv' \
  "$LANES_JSON" >"$LANE_TSV"

N_LANES=0; N_HANDOFF=0; N_SAFE=0; N_NOTSAFE=0; N_MERGED=0; N_NOBRANCH=0

printf '%-4s %-22.22s %-9.9s %-28.28s %-6s %-11s %-7s %-8s %-6s\n' \
  LANE NAME KIND BRANCH ORIGIN A/B HANDOFF VERDICT MERGED
printf '%s\n' "-------------------------------------------------------------------------------------------------------------------"

while IFS="$(printf '\t')" read -r ID NAME KIND BRANCH HANDOFF; do
  [ -n "${ID:-}" ] || continue
  N_LANES=$((N_LANES + 1))

  REF="refs/remotes/origin/$BRANCH"
  ON_ORIGIN=no
  if [ -n "$BRANCH" ] && git show-ref --verify --quiet "$REF"; then
    ON_ORIGIN=yes
  fi

  AB="-"
  HANDOFF_STATE="-"
  VERDICT="-"
  MERGED="-"

  if [ "$ON_ORIGIN" = yes ]; then
    if [ "$HAVE_MAIN" = yes ]; then
      COUNTS="$(git rev-list --left-right --count "origin/main...origin/$BRANCH" 2>/dev/null || true)"
      if [ -n "$COUNTS" ]; then
        BEHIND="$(printf '%s' "$COUNTS" | awk '{print $1}')"
        AHEAD="$(printf '%s' "$COUNTS" | awk '{print $2}')"
        AB="+${AHEAD}/-${BEHIND}"
      fi
      if git merge-base --is-ancestor "origin/$BRANCH" origin/main 2>/dev/null; then
        MERGED=yes; N_MERGED=$((N_MERGED + 1))
      else
        MERGED=no
      fi
    fi

    if [ -n "$HANDOFF" ] && git cat-file -e "origin/$BRANCH:$HANDOFF" 2>/dev/null; then
      HANDOFF_STATE=yes
      N_HANDOFF=$((N_HANDOFF + 1))
      BLOB="$TMPDIR_/handoff.$ID"
      if git show "origin/$BRANCH:$HANDOFF" >"$BLOB" 2>/dev/null; then
        N_NOT="$(grep -c 'NOT SAFE TO INTEGRATE' "$BLOB" || true)"
        N_ALL="$(grep -c 'SAFE TO INTEGRATE' "$BLOB" || true)"
        N_NOT=${N_NOT:-0}; N_ALL=${N_ALL:-0}
        N_BARE=$((N_ALL - N_NOT))
        if [ "$N_NOT" -gt 0 ] && [ "$N_BARE" -gt 0 ]; then
          VERDICT="MIXED!"; N_NOTSAFE=$((N_NOTSAFE + 1))
        elif [ "$N_NOT" -gt 0 ]; then
          VERDICT="NOT-SAFE"; N_NOTSAFE=$((N_NOTSAFE + 1))
        elif [ "$N_BARE" -gt 0 ]; then
          VERDICT="SAFE"; N_SAFE=$((N_SAFE + 1))
        fi
      fi
    else
      HANDOFF_STATE=no
    fi
  else
    N_NOBRANCH=$((N_NOBRANCH + 1))
  fi

  printf '%-4s %-22.22s %-9.9s %-28.28s %-6s %-11s %-7s %-8s %-6s\n' \
    "$ID" "${NAME:--}" "${KIND:--}" "${BRANCH:--}" "$ON_ORIGIN" "$AB" "$HANDOFF_STATE" "$VERDICT" "$MERGED"
done <"$LANE_TSV"

[ "$N_LANES" -eq 0 ] && printf '(no lanes declared in %s)\n' "$LANES_JSON"

printf '\n%s lanes | %s with handoffs | %s SAFE | %s NOT SAFE | %s merged into origin/main' \
  "$N_LANES" "$N_HANDOFF" "$N_SAFE" "$N_NOTSAFE" "$N_MERGED"
[ "$N_NOBRANCH" -gt 0 ] && printf ' | %s branch(es) not on origin yet' "$N_NOBRANCH"
printf '\n'

# --- open escalations --------------------------------------------------------
# An escalation is open until a decision with a loosely matching <date>-<topic>
# exists. Files are searched in the working tree AND in each lane branch's tree,
# because a worker commits its escalation on its own branch.

ESC_LIST="$TMPDIR_/esc.txt"; : >"$ESC_LIST"
DEC_LIST="$TMPDIR_/dec.txt"; : >"$DEC_LIST"

collect_worktree() { # <dir> <outfile>
  [ -d "$1" ] || return 0
  find "$1" -maxdepth 1 -type f -name '*.md' 2>/dev/null | while IFS= read -r f; do
    printf '%s\t(worktree)\n' "$(basename "$f")"
  done >>"$2"
}
collect_worktree "$PROG_DIR/escalations" "$ESC_LIST"
collect_worktree "$PROG_DIR/decisions"   "$DEC_LIST"

while IFS="$(printf '\t')" read -r ID NAME KIND BRANCH HANDOFF; do
  [ -n "${BRANCH:-}" ] || continue
  git show-ref --verify --quiet "refs/remotes/origin/$BRANCH" || continue
  for sub in escalations decisions; do
    OUT="$ESC_LIST"; [ "$sub" = decisions ] && OUT="$DEC_LIST"
    git ls-tree --name-only "origin/$BRANCH" -- "$PROG_DIR/$sub/" 2>/dev/null | while IFS= read -r p; do
      case "$p" in
        *.md) printf '%s\t%s\n' "$(basename "$p")" "origin/$BRANCH" >>"$OUT" ;;
      esac
    done
  done
done <"$LANE_TSV"

key_of() { # strip ESCALATION-/DECISION- prefix and .md suffix
  printf '%s' "${1%.md}" | sed -e 's/^ESCALATION-//' -e 's/^DECISION-//'
}
norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]'; }

DEC_KEYS="$TMPDIR_/deckeys.txt"; : >"$DEC_KEYS"
if [ -s "$DEC_LIST" ]; then
  sort -u "$DEC_LIST" | while IFS="$(printf '\t')" read -r f _src; do
    [ -n "${f:-}" ] || continue
    norm "$(key_of "$f")" >>"$DEC_KEYS"; printf '\n' >>"$DEC_KEYS"
  done
fi

printf '\nOpen escalations (no matching decision):\n'
OPEN=0
if [ -s "$ESC_LIST" ]; then
  SORTED_ESC="$TMPDIR_/esc.sorted"
  sort -u "$ESC_LIST" >"$SORTED_ESC"
  while IFS="$(printf '\t')" read -r f src; do
    [ -n "${f:-}" ] || continue
    NE="$(norm "$(key_of "$f")")"
    [ -n "$NE" ] || continue
    RESOLVED=no
    while IFS= read -r nd; do
      [ -n "${nd:-}" ] || continue
      case "$NE" in *"$nd"*) RESOLVED=yes; break ;; esac
      case "$nd" in *"$NE"*) RESOLVED=yes; break ;; esac
    done <"$DEC_KEYS"
    if [ "$RESOLVED" = no ]; then
      OPEN=$((OPEN + 1))
      printf '  ! %-52s %s\n' "$f" "$src"
    fi
  done <"$SORTED_ESC"
fi
[ "$OPEN" -eq 0 ] && printf '  (none)\n'
printf '\n'
