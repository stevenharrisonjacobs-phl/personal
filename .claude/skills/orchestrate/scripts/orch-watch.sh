#!/usr/bin/env bash
# orch-watch.sh — watch a program's lanes from git so no human has to.
#
# Fetch-poll loop over orchestration/<program>/lanes.json: reports when a lane
# branch's remote tip moves and when its handoff file lands on the branch.
# Exits 0 once every lane that declares a handoff path has one on origin.
#
# This replaces the approver noticing that a worker finished. The measured
# alternative was an 11-hour stall on a reviewer that had already completed.
#
# Read-only with respect to git history: fetches, never commits/pushes/checks out.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: orch-watch.sh <program-slug> [interval-seconds]

Polls origin every interval (default 120s). Prints one line per event:

  HH:MM:SS  lane NN <name>  TIP     <old>..<new>   (branch moved)
  HH:MM:SS  lane NN <name>  HANDOFF landed: <path>
  HH:MM:SS  lane NN <name>  MERGED  into origin/<default>

Exits 0 when every lane with a declared handoff has one on its origin branch.
Ctrl-C to stop early. Subagent-fanout lanes (no branch) are skipped.

Options:
  -h, --help   show this help
EOF
}

die() { printf 'orch-watch: %s\n' "$*" >&2; exit 1; }

case "${1-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -ge 1 ] || { usage >&2; die "expected <program-slug>"; }
SLUG="$1"
INTERVAL="${2:-120}"

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$REPO_ROOT"

LANES_JSON="orchestration/$SLUG/lanes.json"
[ -f "$LANES_JSON" ] || die "no such lane registry: $LANES_JSON"

DEFAULT_BRANCH=main
git show-ref --verify --quiet refs/remotes/origin/main || DEFAULT_BRANCH=master

STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT

lane_rows() {
  jq -r '.lanes[] | select(.branch != null and .branch != "" and .branch != "n/a")
         | [.id, .name, .branch, (.handoff // "")] | @tsv' "$LANES_JSON"
}

now() { date +%H:%M:%S; }

while true; do
  git fetch origin --quiet >/dev/null 2>&1 || \
    printf '%s  warning: git fetch origin failed (offline?)\n' "$(now)" >&2

  all_handoffs=yes
  any_handoff_declared=no

  while IFS=$'\t' read -r id name branch handoff; do
    ref="refs/remotes/origin/$branch"
    key="$STATE_DIR/$(printf '%s' "$branch" | tr -c 'A-Za-z0-9' '_')"

    if ! git show-ref --verify --quiet "$ref"; then
      [ -f "$key.absent" ] || { printf '%s  lane %s %s  (no origin/%s yet)\n' "$(now)" "$id" "$name" "$branch"; touch "$key.absent"; }
      [ -n "$handoff" ] && all_handoffs=no && any_handoff_declared=yes
      continue
    fi

    tip="$(git rev-parse --short "$ref")"
    old="$(cat "$key.tip" 2>/dev/null || true)"
    if [ -z "$old" ]; then
      printf '%s  lane %s %s  TIP     at %s\n' "$(now)" "$id" "$name" "$tip"
    elif [ "$old" != "$tip" ]; then
      printf '%s  lane %s %s  TIP     %s..%s\n' "$(now)" "$id" "$name" "$old" "$tip"
    fi
    printf '%s' "$tip" > "$key.tip"

    if [ -n "$handoff" ]; then
      any_handoff_declared=yes
      if git cat-file -e "$ref:$handoff" 2>/dev/null; then
        [ -f "$key.handoff" ] || { printf '%s  lane %s %s  HANDOFF landed: %s\n' "$(now)" "$id" "$name" "$handoff"; touch "$key.handoff"; }
      else
        all_handoffs=no
      fi
    fi

    if git merge-base --is-ancestor "$ref" "refs/remotes/origin/$DEFAULT_BRANCH" 2>/dev/null; then
      [ -f "$key.merged" ] || { printf '%s  lane %s %s  MERGED  into origin/%s\n' "$(now)" "$id" "$name" "$DEFAULT_BRANCH"; touch "$key.merged"; }
    fi
  done < <(lane_rows)

  if [ "$any_handoff_declared" = yes ] && [ "$all_handoffs" = yes ]; then
    printf '%s  all declared handoffs are on origin — done watching.\n' "$(now)"
    exit 0
  fi

  sleep "$INTERVAL"
done
