---
name: park
description: Frictionless capture — dumps a thought, task, or open loop into the right project file so it leaves Steven's head without breaking his flow. Auto-routes to the project for the current repo (or infers from the note). Use when Steven invokes /park, or says "park this", "note for later", "don't let me forget", "add to <project>", "remind me to…", or drops a mid-task aside he doesn't want to lose.
---

# /park

The externalize-it tool. Steven has ADD — the job is to get a thought out of his
head and into the right place in **one move**, so he can let go of it and keep
working. Bias to capturing fast over asking questions.

Hub: `/Users/stevenjacobs/conductor/repos/personal/projects`

## Step 1 — Route it to a project (and maybe a sub-project)

Projects contain **sub-projects**. Syntax: `/park <project>/<subproject>: <note>`
(e.g. `/park snapfix/outreach: chase pricing prompt`).

1. If Steven named `project/subproject`, use both. If the sub-project doesn't
   exist yet, **create it** (new `### <subproject> · active` block with a NEXT
   placeholder) — don't make him set it up first.
2. If he named only a project (`/park bobsled: …`), route to that project; drop
   the note in `## LOOSE` unless the text obviously belongs to an existing
   sub-project (then use it and say so).
3. Else **auto-detect the project from cwd** via the `repos:` frontmatter match.
4. Else **infer from the note's content**. If you infer, say what you chose.
5. Only if genuinely ambiguous, ask — one short question, 2–3 options.

## Step 2 — Write it

Append as an unchecked, dated item — under the sub-project's loops if one was
resolved, else under `## LOOSE`:

```
- [ ] {the thought, lightly cleaned up}  (added 2026-07-15)
```

If it's clearly the top priority, offer to set it as the sub-project's `NEXT` (or
the project `FOCUS`). If it's blocked on someone, put it under WAITING ON. Bump
`last_touched:` to today.

## Step 3 — Commit & confirm

```bash
git -C /Users/stevenjacobs/conductor/repos/personal add -A
git -C /Users/stevenjacobs/conductor/repos/personal commit -m "park: <project> — <5-word gist>"
```

Confirm in **one line**: `Parked on {project} → "{gist}". Back to it.` Don't
elaborate or summarize — the point is to not break his focus.
