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

Read every `projects/**/*.md`. For each, pull: name, status, NEXT ACTION, count
of open loops, oldest open-loop age, and `last_touched`. Compute staleness from
today (2026-07-15):
- 🟢 fresh (<14d) · 🟡 stale (14–30d) · 🔴 cold (>30d).

## Step 2 — Present the board

Group **Work** then **Personal**. One line per project:

```
# Standup — {Weekday, Mon D}

## Work
🟢 snapfix      → {next action}          · 2 loops · touched 1d ago
🟡 bobsled      → {next action}          · 1 loop  · touched 18d ago
...

## Personal
...

## ⚠️ Needs attention
- 🔴 {project} — cold {N}d, {n} open loops. Still live, or archive it?
- {project} NEXT ACTION still unset.
- {loop} open {N}d with no movement.
```

The **Needs attention** block is the real value — call out every 🔴 cold
project, every unset NEXT ACTION, and any loop aging past ~21 days.

## Step 3 — Offer to act

End with: _"Want me to `/groom` these, or update any next action?"_ If he says
yes, hand off to `/groom`. Then rewrite `projects/INDEX.md` to match the current
state and commit (`standup: refresh dashboard`).
