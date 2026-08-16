#!/usr/bin/env bash
# sync-cowork-plugin.sh — regenerate the Cowork plugin from .claude/skills/.
#
# .claude/skills/ is canonical. The plugin is a BUILD ARTIFACT: never hand-edit
# anything under cowork/plugins/personal/skills/, and never hand-merge it —
# regenerate. Dual-maintained copies drift, and a drifted skill is worse than a
# missing one because it looks current.
#
# Usage:
#   ./scripts/sync-cowork-plugin.sh            # regenerate
#   ./scripts/sync-cowork-plugin.sh --check    # fail if out of date (no writes)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

SRC=".claude/skills"
DEST="cowork/plugins/personal/skills"

# Only the skills that make sense without a laptop. Deliberately EXCLUDED:
#   harness, orchestrate, archive, park, pickup, standup, groom — repo/worktree
#     tooling; meaningless from a Cowork seat with no filesystem.
#   morning, inbound, shows, weather — they shell out to scripts/*.py for Gmail,
#     Calendar, iMessage and Spotify credentials the door does not carry yet.
#     They join when the door grows those domains (spec §8).
SKILLS=(personal finances)

check_only=0
[ "${1:-}" = "--check" ] && check_only=1

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

for skill in "${SKILLS[@]}"; do
  if [ ! -f "$SRC/$skill/SKILL.md" ]; then
    echo "Missing source skill: $SRC/$skill/SKILL.md" >&2
    exit 1
  fi
  mkdir -p "$staging/$skill"
  # -L dereferences symlinks: several skills in .claude/skills are symlinked
  # from the shared harness, and a plugin must ship real files.
  cp -RL "$SRC/$skill/." "$staging/$skill/"
done

# A skill that still tells the reader to run a local script would be a lie in
# Cowork. The shared runbook is the ONE place allowed to name the fallback,
# because explaining the fallback is its job.
offenders=""
while IFS= read -r file; do
  case "$file" in
    "$staging/personal/SKILL.md") continue ;;
  esac
  if grep -qE '(\./)?scripts/query\.sh|\bbq \b' "$file" 2>/dev/null; then
    rel="${file#$staging/}"
    grep -qiE 'locally|fallback|claude code' "$file" || offenders="$offenders\n  $rel"
  fi
done < <(find "$staging" -name '*.md')

if [ -n "$offenders" ]; then
  echo "These plugin skills reference local-only tooling without marking it as the fallback:" >&2
  printf '%b\n' "$offenders" >&2
  echo "Fix the source in $SRC before syncing." >&2
  exit 1
fi

# Written into the staging dir, not after the copy, so --check compares like
# with like. Generating it post-copy made every --check report STALE.
cat > "$staging/README.md" <<'EOF'
GENERATED — do not edit.

These skills are built from `.claude/skills/` by `scripts/sync-cowork-plugin.sh`.
Edit the source there and re-run the script; edits made here are erased on the
next sync.
EOF

if [ "$check_only" -eq 1 ]; then
  if diff -rq "$staging" "$DEST" >/dev/null 2>&1; then
    echo "Plugin is up to date."
    exit 0
  fi
  echo "Plugin is STALE — run ./scripts/sync-cowork-plugin.sh and commit." >&2
  diff -rq "$staging" "$DEST" 2>&1 | head -20 >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$staging" "$DEST"

echo "Synced ${#SKILLS[@]} skills -> $DEST"
find "$DEST" -name '*.md' | sed "s|^$DEST/|  |" | sort

cat <<'EOF'

Release checklist:
  1. Bump "version" in cowork/plugins/personal/.claude-plugin/plugin.json
     (and cowork/VERSION), then commit and push to main.
  2. In claude.ai: Customize > Plugins > update. Sync is NOT near-real-time.
  3. If the DOOR's toolset changed, remove and re-add the connector — a
     connector snapshots its tool list when added.
EOF
