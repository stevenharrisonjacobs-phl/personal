---
name: standup
description: The cross-project sweep — one dashboard of every project's next action, plus what's gone stale or cold so forgotten work resurfaces. Use when Steven invokes /standup, or asks "where am I across everything", "what's on all my plates", "what am I forgetting", "give me the rundown", or wants a portfolio-level status.
---

# /standup

Give Steven the whole board at a glance and, critically, **surface what he's
dropped**. This is the ADD safety net — cold projects and stale loops must jump
out, not hide.

Hub: `/Users/stevenjacobs/conductor/repos/personal/projects`

## Step 1 — Read everything

Read every `projects/**/*.md`. For each project pull: name, status, `FOCUS`, its
**sub-projects** (name + status + NEXT + loop count), LOOSE loop count, oldest
open-loop age, and `last_touched`. Staleness from today (2026-07-15):
- 🟢 fresh (<14d) · 🟡 stale (14–30d) · 🔴 cold (>30d).

## Step 2 — Present the board

Group **Work** then **Personal**. One line per project (FOCUS + sub-project
count); indent sub-projects only when they need attention or Steven asks for the
expanded view.

```
# Standup — {Weekday, Mon D}

## Work
🟢 snapfix     FOCUS → {focus}        · 3 sub · touched 1d ago
🟡 bobsled     FOCUS → {focus}        · 2 sub · touched 18d ago
...

## Personal
...

## ⚠️ Needs attention
- 🔴 snapfix / {sub} — cold {N}d, {n} loops. Still live, or archive it?
- {project} FOCUS unset, or {sub}'s NEXT unset.
- {loop} open {N}d with no movement.
```

The **Needs attention** block is the real value — drill to the **sub-project**
level here: call out every 🔴 cold sub-project, every unset FOCUS/NEXT, and any
loop aging past ~21 days.

## Step 3 — Offer to act

End with: _"Want me to `/groom` these, or update any next action?"_ If he says
yes, hand off to `/groom`. Then rewrite `projects/INDEX.md` to match the current
state and commit (`standup: refresh dashboard`).
