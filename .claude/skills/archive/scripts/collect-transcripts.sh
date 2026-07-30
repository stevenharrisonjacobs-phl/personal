#!/usr/bin/env bash
#
# collect-transcripts.sh — durably capture a Conductor workspace's Claude Code
# session transcripts before the workspace (git worktree) is archived/deleted.
#
# Claude Code stores transcripts at:
#   ~/.claude/projects/<path-with-slashes-as-dashes>/<sessionId>.jsonl
# That folder is keyed by the workspace PATH. Conductor reuses city names, so a
# future workspace with the same name could orphan or co-mingle these files.
# This script copies them to a date-stamped archive dir that will never be
# reused, and prints a Markdown manifest for the ARCHIVE handoff doc.
#
# Usage:
#   collect-transcripts.sh [workspace_dir]   # defaults to $PWD
#
# Env:
#   ARCHIVE_ROOT   override archive location. Default: iCloud Drive if present
#                  (syncs to your other Mac when both use the same Apple ID),
#                  else ~/.claude/conductor-archives (machine-local).
#   DRY_RUN=1      list transcripts + manifest, copy nothing

set -euo pipefail

WS_DIR="${1:-$PWD}"
WS_DIR="$(cd "$WS_DIR" && pwd -P)"          # canonical absolute path
WS_NAME="$(basename "$WS_DIR")"

# Default to a cross-machine synced location so archives are reachable from
# either Mac. iCloud Drive syncs automatically when both machines share an
# Apple ID; override with ARCHIVE_ROOT to use GCS/another synced folder.
ICLOUD_DRIVE="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
if [[ -n "${ARCHIVE_ROOT:-}" ]]; then
  :   # caller-specified, honor it
elif [[ -d "$ICLOUD_DRIVE" ]]; then
  ARCHIVE_ROOT="$ICLOUD_DRIVE/conductor-archives"
else
  ARCHIVE_ROOT="$HOME/.claude/conductor-archives"
fi

# Derive the Claude Code project slug: leading dash + all slashes -> dashes.
SLUG="$(printf '%s' "$WS_DIR" | sed 's|/|-|g')"
PROJ_DIR="$HOME/.claude/projects/$SLUG"

# Name the archive dir after the WORKSPACE + date, not the branch. During an
# archive run you may create throwaway branches (e.g. to split unrelated loose
# ends into separate PRs); the branch is an artifact of the process, not the
# workspace's identity. The branch is still recorded in the manifest below.
BRANCH="$(git -C "$WS_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)"
DATESTAMP="$(date +%Y-%m-%d)"
DEST="$ARCHIVE_ROOT/${WS_NAME}-${DATESTAMP}"

if [[ ! -d "$PROJ_DIR" ]]; then
  echo "NO_TRANSCRIPTS: no project dir at $PROJ_DIR" >&2
  echo "(workspace may never have run Claude Code, or the path slug differs)" >&2
  exit 3
fi

shopt -s nullglob
FILES=("$PROJ_DIR"/*.jsonl)
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "NO_TRANSCRIPTS: no .jsonl files in $PROJ_DIR" >&2
  exit 3
fi

# --- human-readable status to stderr ---
echo "Workspace:    $WS_DIR"       >&2
echo "Branch:       $BRANCH"        >&2
echo "Project dir:  $PROJ_DIR"      >&2
echo "Sessions:     ${#FILES[@]}"   >&2
echo "Archive dest: $DEST"          >&2
echo                                >&2

if [[ "${DRY_RUN:-0}" != "1" ]]; then
  mkdir -p "$DEST/transcripts"
  cp -p "${FILES[@]}" "$DEST/transcripts/"
fi

# --- Markdown manifest to stdout (paste into ARCHIVE doc) ---
echo "## Session transcripts"
echo
echo "Archived to \`$DEST/transcripts/\` on $DATESTAMP (branch at capture: \`$BRANCH\`)."
echo "Original live path: \`$PROJ_DIR\`"
echo "(may be reused by a future workspace of the same name)."
echo
echo "| Session ID | Msgs | Size | First activity | Last activity |"
echo "|---|---|---|---|---|"
for f in "${FILES[@]}"; do
  sid="$(basename "$f" .jsonl)"
  lines="$(wc -l < "$f" | tr -d ' ')"
  size="$(du -h "$f" | cut -f1)"
  # ``grep | head`` exits 141 under pipefail when grep receives SIGPIPE after
  # the first match. Let grep stop itself after one match instead. Some session
  # formats may omit timestamps, so an empty value should render as "?" rather
  # than aborting the entire archive.
  first_ts="$(grep -m 1 -o '"timestamp":"[^"]*"' "$f" | sed 's/"timestamp":"//;s/"//' || true)"
  last_ts="$(grep -o '"timestamp":"[^"]*"' "$f" | tail -1 | sed 's/"timestamp":"//;s/"//' || true)"
  echo "| \`$sid\` | $lines | $size | ${first_ts:-?} | ${last_ts:-?} |"
done
echo
echo "_To replay a session for debugging:_ \`cat \"$DEST/transcripts/<session-id>.jsonl\" | jq -r 'select(.type==\"user\" or .type==\"assistant\")'\`"
