#!/usr/bin/env bash
# orch-init.sh — scaffold a new orchestrator/worker program on the orchestration bus.
#
# Read-only with respect to git history: never commits, pushes, checks out, resets,
# or rewrites refs. The only git write is a best-effort `git fetch origin`, used
# solely to read the current origin/main sha for the lane registry's `base`.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: orch-init.sh <program-slug>

Creates the committed orchestration bus for a new program:

  orchestration/<program-slug>/
    PLAN.md          prose: goal, frozen contracts, waves, approvals
    lanes.json       machine-readable lane registry (orch-status.sh and
                     orch-scope-audit.sh read this)
    lanes/           one NN-<lane>.md worker brief per lane (from templates/LANE.md)
    escalations/     ESCALATION-<date>-<topic>.md
    decisions/       DECISION-<date>-<topic>.md
    STATUS.md        orchestrator-maintained state ladder

Also creates orchestration/CURRENT.md if absent and appends a row for this program
so a standing orchestrator stays findable.

Refuses (exit 1) if orchestration/<program-slug>/ already exists.

Options:
  -h, --help   show this help
EOF
}

die() { printf 'orch-init: %s\n' "$*" >&2; exit 1; }

case "${1-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -eq 1 ] || { usage >&2; die "expected exactly one argument (<program-slug>), got $#"; }

SLUG="$1"
case "$SLUG" in
  *[!A-Za-z0-9._-]*|"") die "invalid program slug '$SLUG' — use only [A-Za-z0-9._-]" ;;
  .|..) die "invalid program slug '$SLUG'" ;;
esac

command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH. Install it (brew install jq) and re-run."

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$REPO_ROOT"

# Resolve the skill from THIS script's location, so it works whether the skill is
# installed globally (~/.claude/skills/orchestrate, usually a symlink) or vendored
# into the repo. Hardcoding the repo path silently degraded to the stub template.
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUS_DIR="$REPO_ROOT/orchestration"
PROG_DIR="$BUS_DIR/$SLUG"
CURRENT_MD="$BUS_DIR/CURRENT.md"
TODAY="$(date +%Y-%m-%d)"
REPO_NAME="$(basename "$REPO_ROOT")"

[ -e "$PROG_DIR" ] && die "orchestration/$SLUG already exists — refusing to overwrite it. Pick another slug or remove it deliberately."

# --- resolve base + orchestrator branch -------------------------------------
git fetch origin --quiet >/dev/null 2>&1 || printf 'orch-init: warning: git fetch origin failed (offline?); using local refs.\n' >&2

BASE_SHA="$(git rev-parse origin/main 2>/dev/null || true)"
if [ -z "$BASE_SHA" ]; then
  BASE_SHA="$(git rev-parse main 2>/dev/null || true)"
  [ -n "$BASE_SHA" ] && printf 'orch-init: warning: origin/main not found; used local main as base.\n' >&2
fi
if [ -z "$BASE_SHA" ]; then
  printf 'orch-init: warning: neither origin/main nor main resolved; lanes.json base is empty — fill it in by hand.\n' >&2
fi

ORCH_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[ "$ORCH_BRANCH" = "HEAD" ] && ORCH_BRANCH=""

# --- scaffold ----------------------------------------------------------------
mkdir -p "$PROG_DIR/lanes" "$PROG_DIR/escalations" "$PROG_DIR/decisions"

# Keep the empty dirs meaningful in git.
for d in lanes escalations decisions; do
  [ -e "$PROG_DIR/$d/.gitkeep" ] || : >"$PROG_DIR/$d/.gitkeep"
done

# PLAN.md — from template if present, otherwise a stub.
PLAN_TEMPLATE="$SKILL_DIR/templates/PLAN.md"
if [ -f "$PLAN_TEMPLATE" ]; then
  cp "$PLAN_TEMPLATE" "$PROG_DIR/PLAN.md"
  PLAN_SOURCE="templates/PLAN.md"
else
  PLAN_SOURCE="stub (templates/PLAN.md not found)"
  cat >"$PROG_DIR/PLAN.md" <<EOF
# $SLUG — program plan

> Stub written by \`orch-init.sh\` on $TODAY because
> \`$SKILL_DIR/templates/PLAN.md\` did not exist. Fill every
> section before dispatching a single lane.

**Kind:** program | standing · **Orchestrator branch:** \`${ORCH_BRANCH:-<branch>}\`
**Base:** \`origin/main\` @ \`${BASE_SHA:-<sha>}\`

## 1. Goal

<What is true when this is done, stated so a cold reader can check it.>

## 2. Why this is a program

<Two or more of: multiple judgment streams; irreversible/external action; spans
more than a day; more than one lane would edit the same shared file.>

## 3. Frozen contracts

Freeze the interface, then parallelize. Consumers build against these
immediately — not audit-only. A contract change is an escalation the
orchestrator fans out, never a reason for a lane to idle.

| Contract file | Pinned at | Consumers |
|---|---|---|
| \`<path>\` | \`<sha or digest>\` | lanes <ids> |

## 4. Lanes and waves

One workspace per in-flight judgment stream. Work that runs agent-to-end and
needs only a transactional approve/reject at a gate is subagent fan-out inside
an existing workspace, not a new one — and every lane brief must authorize that
fan-out explicitly.

| Wave | Lane | Kind | Branch | Depends on |
|---|---|---|---|---|
| 1 | 01-<lane> | workspace | \`<branch>\` | nothing |

## 5. Shared files — orchestrator-owned, resolved exactly once

\`CLAUDE.md\`, \`README.md\`, CI workflows, cross-domain packages. Lanes request
changes to these in their handoff; they never edit them.

## 6. Approvals

Nothing inherits authority. Every external action needs its own named,
separately granted token, pasted as an editable block, with the non-grants
enumerated.

- **A1:** <exact bounded external action> — NOT GRANTED
- **A2:** <…> — NOT GRANTED

## 7. Gates

A lane cannot author its own gate. Each lane's acceptance command is authored by
the orchestrator or the reviewer, and must be wired into the default CI path — a
gate not invoked by default is not a gate.

## 8. Integration order

<dependency order; central integration only; archival is not a substitute for
merging.>

## 9. Closeout

<CLOSEOUT.md; verify every lane branch is an ancestor of origin/main before
telling the approver which workspaces are safe to archive.>
EOF
fi

# lanes.json — built through jq so it is always valid JSON.
jq -n \
  --arg program "$SLUG" \
  --arg base "$BASE_SHA" \
  --arg orch_branch "$ORCH_BRANCH" \
  --arg handoff "docs/HANDOFF-$TODAY-<lane>.md" \
  '{
     program: $program,
     standing: false,
     base: $base,
     orchestrator_branch: $orch_branch,
     lanes: [
       {
         id: "01",
         name: "<lane-name>",
         branch: "<branch>",
         kind: "workspace",
         owns: ["path/glob/**"],
         forbids: ["CLAUDE.md"],
         handoff: $handoff,
         approvals: [],
         gate: "<exact acceptance command>",
         gate_author: "orchestrator",
         depends_on: []
       }
     ]
   }' >"$PROG_DIR/lanes.json"

cat >"$PROG_DIR/STATUS.md" <<EOF
# $SLUG — status

Orchestrator-maintained. Recompute from git; recorded booleans are assertions.
\`bash "$SKILL_DIR/scripts/orch-status.sh" $SLUG\` is the fast read.

**Kind:** program · **Orchestrator branch:** \`${ORCH_BRANCH:-<branch>}\`
**Base:** \`${BASE_SHA:-<sha>}\` · **Started:** $TODAY

## State ladder

Anything can be "done" at more than one level. Every status names the rung.

| Lane | Branch | Built | Self-evidenced | Reviewed | Gate passed | Approved | Integrated | Reconciled |
|---|---|---|---|---|---|---|---|---|
| 01-<lane> | \`<branch>\` | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |

## Open escalations

<none yet — see escalations/ and decisions/>

## Log

- $TODAY — program initialized by \`orch-init.sh\`.
EOF

# --- CURRENT.md --------------------------------------------------------------
CURRENT_CREATED=no
if [ ! -f "$CURRENT_MD" ]; then
  CURRENT_CREATED=yes
  cat >"$CURRENT_MD" <<'EOF'
# Active orchestration programs

This file names every active orchestrator/worker program and the branch its
orchestrator is running on, so a standing orchestrator is findable from a cold
start — from any workspace, without a paste, and without guessing.

## Programs

| Program | Kind (program/standing) | Orchestrator branch | Status | Started |
|---|---|---|---|---|
<!-- ORCH-PROGRAMS -->

> A standing program's orchestrator branch **MUST** be kept current in this
> table. Two workspaces once held byte-identical decision documents with nothing
> on disk saying which was authoritative — the only way to tell them apart was to
> ask a human who happened to remember. This table is that answer, committed.
>
> `program` dies at closeout; `standing` accumulates `decisions/` forever and its
> row stays until the fleet itself is retired.
EOF
fi

ROW="| $SLUG | program | \`${ORCH_BRANCH:-<branch>}\` | initialized | $TODAY |"
if grep -qF "| $SLUG |" "$CURRENT_MD" 2>/dev/null; then
  printf 'orch-init: note: CURRENT.md already lists "%s" — row not duplicated.\n' "$SLUG"
elif grep -qF '<!-- ORCH-PROGRAMS -->' "$CURRENT_MD"; then
  TMP="$(mktemp)"
  awk -v row="$ROW" '
    { print }
    !inserted && index($0, "<!-- ORCH-PROGRAMS -->") { print row; inserted = 1 }
  ' "$CURRENT_MD" >"$TMP"
  mv "$TMP" "$CURRENT_MD"
else
  printf 'orch-init: warning: no <!-- ORCH-PROGRAMS --> marker in CURRENT.md; appending row at end of file.\n' >&2
  printf '%s\n' "$ROW" >>"$CURRENT_MD"
fi

# --- report ------------------------------------------------------------------
cat <<EOF

Initialized orchestration/$SLUG

  PLAN.md      <- $PLAN_SOURCE
  lanes.json   base=${BASE_SHA:-<unset>} orchestrator_branch=${ORCH_BRANCH:-<unset>}
  lanes/ escalations/ decisions/ STATUS.md
  CURRENT.md   $([ "$CURRENT_CREATED" = yes ] && echo "created + row added" || echo "row added")

Next steps:

  1. Fill orchestration/$SLUG/PLAN.md — goal, frozen contracts, waves, approvals.
     Freeze the contracts BEFORE splitting lanes; that is what makes them concurrent.
  2. Edit orchestration/$SLUG/lanes.json — one entry per lane. Every lane needs
     disjoint \`owns\` globs (one writer per path-scope), an explicit \`forbids\`
     list, and a \`gate\` you authored. A lane may not author its own gate.
  3. Write orchestration/$SLUG/lanes/NN-<lane>.md from
     $SKILL_DIR/templates/LANE.md — one per lane.
  4. Commit the bus. It must survive the worktree; .context/ does not.
  5. Hand the approver the four-line pointer per lane:

       You are the worker for lane NN of program $SLUG in $REPO_NAME.
       git fetch origin && git checkout -b <branch> origin/main
       Read orchestration/$SLUG/lanes/NN-<lane>.md and follow it exactly.
       Granted approvals: A1 only. No others.

  6. Check on it:
       bash "$SKILL_DIR/scripts/orch-status.sh" $SLUG
       bash "$SKILL_DIR/scripts/orch-scope-audit.sh" $SLUG
EOF
