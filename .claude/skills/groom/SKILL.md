---
name: groom
description: The pruning pass — keeps the project tracker trustworthy by proposing which loops to close, archive, merge, or de-stale, then applying only what Steven approves. Archives, never deletes. Use when Steven invokes /groom, or says "clean up my projects", "prune this", "tidy the tracker", "these are stale", or after /standup flags rot.
---

# /groom

Fight the failure mode that kills every tracking system: rot. Stale, duplicate,
and done-but-still-listed items pile up until Steven stops trusting the tracker
and abandons it. Grooming keeps it honest. **You do the judgment; Steven does the
approving.**

Hub: `/Users/stevenjacobs/conductor/repos/personal/projects`

## Two hard rules

1. **Archive, never delete.** Done/dropped loops move to the file's `## ARCHIVE`
   section (checked off, with a dated note). Nothing ever vanishes — that's the
   trust contract.
2. **Propose, then apply.** Never silently rewrite. Show a numbered batch of
   proposed changes; apply only what Steven approves (he can say "all", "1,3",
   "skip 2", etc.).

## Step 1 — Scope

Default: all projects. If Steven named one (`/groom snapfix`), just that. Read the
file(s).

## Step 2 — Build the proposal batch

Work at the **sub-project** grain. For each project and each sub-project, look
for:
- **Done loops** still listed → propose check-off + move to ARCHIVE.
- **Finished sub-projects** (all loops done / shipped) → propose archiving the
  whole sub-project block, not just its loops.
- **Stale loops** (no movement ~21d+) → propose: still live, or archive? Ask;
  don't assume dead.
- **Duplicate / overlapping loops or sub-projects** → propose a merge into one.
- **Bloated NEXT / FOCUS** (multiple things, or vague) → propose tightening to one
  concrete physical action.
- **Cold sub-project or project** (🔴 >30d) → propose a status change (`paused` /
  `winding-down`) or confirm it's still active.
- **Unset FOCUS or sub-project NEXT** → ask Steven for it.

Present as a tight numbered list, grouped by project, each line: what + why.

```
## Proposed grooming

snapfix
 1. Archive "draft ICP deck" — checked off in LOG 6d ago, still in loops.
 2. Merge loops 3 & 5 (both about the pricing follow-up).

bobsled
 3. 🔴 cold 34d — mark `paused`, or what's the next action?
```

## Step 3 — Apply approved changes

For each approved item: edit the file (move to ARCHIVE with a dated note, merge,
tighten, or restatus), bump `last_touched:` only where content genuinely changed,
then rewrite `projects/INDEX.md`. Commit once:
`git -C /Users/stevenjacobs/conductor/repos/personal add -A && ... commit -m "groom: prune N items across M projects"`.

Report what changed in ≤3 lines. Leave the board cleaner than you found it.
