#!/usr/bin/env bash
#
# collect-transcripts.sh — durably capture a Conductor workspace's Codex CLI
# session transcripts before the workspace (git worktree) is archived/deleted.
#
# Codex stores session "rollouts" at:
#   $CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl   (CODEX_HOME defaults to ~/.codex)
# Unlike Claude Code (which keys a project dir by workspace PATH), Codex files
# them by DATE, and records the workspace path as `payload.cwd` in each file's
# first `session_meta` line. So we can't glob by path — we scan every rollout
# and keep the ones whose recorded cwd matches this workspace.
#
# This copies matches to a date-stamped archive dir that will never be reused,
# and prints a Markdown manifest for the ARCHIVE handoff doc.
#
# Usage:
#   collect-transcripts.sh [workspace_dir]   # defaults to $PWD
#
# Env:
#   CODEX_HOME     Codex home dir. Default: ~/.codex
#   ARCHIVE_ROOT   override archive location. Default: iCloud Drive if present
#                  (syncs to your other Mac when both use the same Apple ID),
#                  else ~/.codex/conductor-archives (machine-local).
#   SINCE_DAYS     only scan rollouts modified in the last N days (speeds up a
#                  large history). Default: scan all.
#   DRY_RUN=1      list transcripts + manifest, copy nothing

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 2; }

RAW_WS="${1:-$PWD}"
WS_DIR="$(cd "$RAW_WS" && pwd -P)"          # canonical absolute path
RAW_WS="$(cd "$RAW_WS" 2>/dev/null && pwd || echo "$RAW_WS")"  # logical path (may keep symlinks)
WS_NAME="$(basename "$WS_DIR")"

# Codex records `cwd` as the process working dir, which may or may not be
# symlink-resolved; `pwd -P` above resolves it. Normalize both sides (strip a
# leading /private, macOS's /var -> /private/var symlink) so the match is robust.
_norm() { case "$1" in /private/*) printf '%s' "${1#/private}";; *) printf '%s' "$1";; esac; }
WS_NORM="$(_norm "$WS_DIR")"
RAW_NORM="$(_norm "$RAW_WS")"

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
SESS_DIR="$CODEX_HOME/sessions"

# Default to a cross-machine synced location so archives are reachable from
# either Mac. iCloud Drive syncs automatically when both machines share an
# Apple ID; override with ARCHIVE_ROOT to use GCS/another synced folder.
ICLOUD_DRIVE="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
if [[ -n "${ARCHIVE_ROOT:-}" ]]; then
  :   # caller-specified, honor it
elif [[ -d "$ICLOUD_DRIVE" ]]; then
  ARCHIVE_ROOT="$ICLOUD_DRIVE/conductor-archives"
else
  ARCHIVE_ROOT="$CODEX_HOME/conductor-archives"
fi

# Name the archive dir after the WORKSPACE + date, not the branch. During an
# archive run you may create throwaway branches (e.g. to split unrelated loose
# ends into separate PRs); the branch is an artifact of the process, not the
# workspace's identity. The branch is still recorded in the manifest below.
BRANCH="$(git -C "$WS_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)"
DATESTAMP="$(date +%Y-%m-%d)"
DEST="$ARCHIVE_ROOT/${WS_NAME}-${DATESTAMP}"

if [[ ! -d "$SESS_DIR" ]]; then
  echo "NO_TRANSCRIPTS: no Codex sessions dir at $SESS_DIR" >&2
  echo "(CODEX_HOME may differ; set CODEX_HOME to override)" >&2
  exit 3
fi

# Gather candidate rollout files (optionally limited to recent ones).
shopt -s nullglob
FIND_ARGS=("$SESS_DIR" -type f -name 'rollout-*.jsonl')
if [[ -n "${SINCE_DAYS:-}" ]]; then
  FIND_ARGS+=(-mtime "-${SINCE_DAYS}")
fi

# Match on the cwd recorded in each rollout's first session_meta line.
MATCHES=()
while IFS= read -r f; do
  cwd="$(head -n 20 "$f" 2>/dev/null \
          | jq -r 'select(.type=="session_meta") | .payload.cwd // empty' 2>/dev/null \
          | head -n 1 || true)"
  [[ -z "$cwd" ]] && continue
  cwd_norm="$(_norm "$cwd")"
  if [[ "$cwd_norm" == "$WS_NORM" || "$cwd_norm" == "$RAW_NORM" ]]; then
    MATCHES+=("$f")
  fi
done < <(find "${FIND_ARGS[@]}" 2>/dev/null)

if [[ ${#MATCHES[@]} -eq 0 ]]; then
  echo "NO_TRANSCRIPTS: no Codex rollouts with cwd == $WS_DIR" >&2
  echo "(workspace may never have run Codex, or ran under a different path)" >&2
  exit 3
fi

# --- human-readable status to stderr ---
echo "Workspace:    $WS_DIR"          >&2
echo "Branch:       $BRANCH"           >&2
echo "Sessions dir: $SESS_DIR"         >&2
echo "Matched:      ${#MATCHES[@]} rollout(s)" >&2
echo "Archive dest: $DEST"             >&2
echo                                   >&2

if [[ "${DRY_RUN:-0}" != "1" ]]; then
  mkdir -p "$DEST/transcripts"
  cp -p "${MATCHES[@]}" "$DEST/transcripts/"
fi

# --- Markdown manifest to stdout (paste into ARCHIVE doc) ---
echo "## Session transcripts (Codex)"
echo
echo "Archived to \`$DEST/transcripts/\` on $DATESTAMP (branch at capture: \`$BRANCH\`)."
echo "Source: Codex rollouts under \`$SESS_DIR\` whose \`session_meta.payload.cwd\` == \`$WS_DIR\`."
echo
echo "| Session ID | Msgs | Size | First activity | Last activity |"
echo "|---|---|---|---|---|"
for f in "${MATCHES[@]}"; do
  sid="$(head -n 20 "$f" | jq -r 'select(.type=="session_meta") | .payload.id // empty' | head -n 1)"
  [[ -z "$sid" ]] && sid="$(basename "$f" .jsonl)"
  lines="$(wc -l < "$f" | tr -d ' ')"
  size="$(du -h "$f" | cut -f1)"
  # grep -m1 stops after the first match (avoids SIGPIPE 141 under pipefail).
  first_ts="$(grep -m 1 -o '"timestamp":"[^"]*"' "$f" | sed 's/"timestamp":"//;s/"//' || true)"
  last_ts="$(grep -o '"timestamp":"[^"]*"' "$f" | tail -1 | sed 's/"timestamp":"//;s/"//' || true)"
  echo "| \`$sid\` | $lines | $size | ${first_ts:-?} | ${last_ts:-?} |"
done
echo
echo "_To replay a session for debugging:_ \`cat \"$DEST/transcripts/<file>.jsonl\" | jq -r 'select(.type==\"response_item\") | .payload'\`"
