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

Every file leads with the same sections so resuming is brainless:

- **NEXT ACTION** — the single next physical thing. One line. If you read nothing
  else, you know what to do.
- **OPEN LOOPS** — started-but-unfinished threads, `[ ]` checkboxes, each dated.
- **WAITING ON** — blocked on someone else (who + since when).
- **LOG** — dated one-liners of what happened. Newest at top.
- **ARCHIVE** — done/dropped loops move here. **Never deleted** — the system only
  ever archives, so it stays trustworthy.

The frontmatter (`repos:`, `last_touched:`, `status:`) powers auto-detection and
staleness flags — leave it in place.

## The skills that drive this

Available in **every** repo (installed at `~/.claude/skills/`, sourced from
`../.claude/skills/`):

- **`/pickup [project]`** — auto-detects the project from whichever repo you're
  in; shows NEXT ACTION + open loops. Your "where was I."
- **`/park "<thought>"`** — capture an open loop mid-flow without losing focus.
- **`/standup`** — sweep across all projects; flags stale + cold ones.
- **`/groom`** — deep prune pass; proposes archive/merge/close, you approve.

Grooming also runs passively inside `/morning`, which surfaces stale loops daily.
