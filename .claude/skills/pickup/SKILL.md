---
name: pickup
description: "Where was I?" — resurfaces a project's single NEXT ACTION plus its open loops so Steven can resume instantly without reconstructing context. Auto-detects the project from whichever repo the session is in. Use when Steven invokes /pickup, or asks "where was I", "what was I doing on X", "pick up where I left off", "what's next on <project>".
---

# /pickup

Answer one question: **what's the next thing to do on this project, and what's
still open?** Optimize for zero-effort resumption — Steven has ADD; the whole
point is he shouldn't have to rebuild context in his head.

Hub (always absolute — this skill runs from any repo):
`/Users/stevenjacobs/conductor/repos/personal/projects`

## Step 1 — Pick the project

1. If Steven named one (`/pickup bobsled`), use it.
2. Else **auto-detect from cwd**: read the `repos:` frontmatter in each
   `projects/**/*.md` and match any entry that is a substring of `$PWD`. The
   snapfix repo → `snapfix.md`, `bobsled-agents` → `bobsled.md`, etc.
3. If no match (e.g. you're in the personal repo or a neutral dir), show the
   one-line NEXT ACTION for **every** project and ask which to open.

## Step 2 — Read & present

Projects have **sub-projects**. Each file has a project-level `## FOCUS` (which
sub-project matters now) and a `## Sub-projects` section where each sub-project
carries its own `**NEXT** →` line + loops, plus a `## LOOSE` bucket for loops not
tied to a sub-project.

**Default (`/pickup snapfix`)** — show the tree collapsed, so Steven can steer:

```
📌 {Project}  ·  last touched {N days ago}

FOCUS → {the project-level one-liner}

Sub-projects
  ▸ {sub} · {status}   NEXT → {one line}   ({n} loops)
  ▸ {sub} · {status}   NEXT → {one line}
LOOSE ({n})   ← show count only unless empty is notable
```

**Drill in (`/pickup snapfix outreach` or `/pickup snapfix:outreach`)** — expand
just that sub-project: its NEXT, all its loops with ages, waiting-on.

Keep the collapsed view under ~15 lines. Lead with FOCUS, then the sub-project
NEXTs — that tree is the payload. If a project has no sub-projects yet, fall back
to showing FOCUS + LOOSE loops and offer to create one.

## Step 3 — Micro-groom (only if warranted)

- If `last_touched` > 14 days, add one line: _"⚠️ stale — is that FOCUS / NEXT
  still right?"_ and offer to update it.
- If FOCUS or a sub-project's NEXT is still a placeholder, ask Steven and write
  it in.
- If he tells you what he just did or what's next, update the file: refresh
  NEXT ACTION, check off / add loops, append a dated LOG line, bump
  `last_touched`, then commit (see below).

## Writing back

Any change to a project file: update `last_touched:` to today, then
`git -C /Users/stevenjacobs/conductor/repos/personal add -A && git ... commit`
with a short message like `pickup: update snapfix next action`. Never delete a
loop — check it off and move it to ARCHIVE. Confirm in one line.
