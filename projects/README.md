# Projects — Steven's cross-project tracker

Live **state** for everything Steven is running, so nothing gets dropped or
forgotten mid-flight. This is the "where am I / what's next" layer. The "who's
who / cadences" reference lives in [`../docs/people-and-workstreams.md`](../docs/people-and-workstreams.md) —
don't duplicate it here; link to it.

## Layout

```
projects/
  INDEX.md            ← cross-project dashboard (maintained by /standup + /groom)
  work/
    bobsled.md        client · half-time
    snapfix.md        client · Plum Growth's first client
    fkt.md            client
    plum-growth.md    ops · Steven's agency
  personal/
    family.md
    friends.md
```

## How each file is shaped

A project is **not one thing** — it's several sub-projects, each with its own
next step. So every file has two levels:

- **FOCUS** — one line: which sub-project (or thing) is the priority *right now*.
  The steering wheel. If you read nothing else, this tells you where to point.
- **Sub-projects** — the real unit of work. Each is a `### <name> · <status>`
  block carrying its **own** `**NEXT** →` line and its own dated `[ ]` loops.
  Statuses: `active` / `paused` / `blocked` / `done`. A sub-project that grows
  big can *graduate* into its own file later.
- **LOOSE** — loops not (yet) tied to a sub-project. The inbox.
- **WAITING ON** — blocked on someone else (who + since when).
- **LOG** — dated one-liners of what happened. Newest at top.
- **ARCHIVE** — done/dropped loops *and finished sub-projects* move here. **Never
  deleted** — the system only ever archives, so it stays trustworthy.

Create a sub-project just by parking into it: `/park snapfix/outreach: <thought>`
creates the `outreach` sub-project if it doesn't exist. The frontmatter
(`repos:`, `last_touched:`, `status:`) powers auto-detection and staleness flags
— leave it in place.

## The skills that drive this

Available in **every** repo (installed at `~/.claude/skills/`, sourced from
`../.claude/skills/`):

- **`/pickup [project]`** — auto-detects the project from whichever repo you're
  in; shows NEXT ACTION + open loops. Your "where was I."
- **`/park "<thought>"`** — capture an open loop mid-flow without losing focus.
- **`/standup`** — sweep across all projects; flags stale + cold ones.
- **`/groom`** — deep prune pass; proposes archive/merge/close, you approve.

Grooming also runs passively inside `/morning`, which surfaces stale loops daily.
