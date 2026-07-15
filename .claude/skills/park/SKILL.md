---
name: park
description: Frictionless capture — dumps a thought, task, or open loop into the right project file so it leaves Steven's head without breaking his flow. Auto-routes to the project for the current repo (or infers from the note). Use when Steven invokes /park, or says "park this", "note for later", "don't let me forget", "add to <project>", "remind me to…", or drops a mid-task aside he doesn't want to lose.
---

# /park

The externalize-it tool. Steven has ADD — the job is to get a thought out of his
head and into the right place in **one move**, so he can let go of it and keep
working. Bias to capturing fast over asking questions.

Hub: `/Users/stevenjacobs/conductor/repos/personal/projects`

## Step 1 — Route it to a project

1. If Steven named one (`/park bobsled: chase Josh on pricing`), use it.
2. Else **auto-detect from cwd** via the `repos:` frontmatter match (same as
   `/pickup`).
3. Else **infer from the note's content** (a name/company in the text → its
   project). If you infer, say which project you chose so he can redirect.
4. Only if genuinely ambiguous, ask — one short question, offer 2–3 options.

## Step 2 — Write it

Append to the project's **OPEN LOOPS** as an unchecked item with today's date:

```
- [ ] {the thought, lightly cleaned up}  (added 2026-07-15)
```

If it's clearly the single most important next thing, also offer to set it as
NEXT ACTION. If it's a blocker on someone else, put it under WAITING ON instead.
Bump `last_touched:` to today.

## Step 3 — Commit & confirm

```bash
git -C /Users/stevenjacobs/conductor/repos/personal add -A
git -C /Users/stevenjacobs/conductor/repos/personal commit -m "park: <project> — <5-word gist>"
```

Confirm in **one line**: `Parked on {project} → "{gist}". Back to it.` Don't
elaborate or summarize — the point is to not break his focus.
