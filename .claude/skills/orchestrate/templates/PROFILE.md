<!-- Repo profile for /orchestrate. Copy to <repo-root>/orchestration/PROFILE.md,
     fill every section, and COMMIT it.

     This file is the repo-specific half of the skill. The skill supplies the
     structure — the loop, the invariants, the artifacts, the scripts. This
     supplies the six things that are different in every repo. Where the two
     disagree, THIS FILE WINS.

     Fill it by MEASURING, not remembering: run the commands, read the config,
     hit the live system. Everything here is a claim someone will act on. -->

# Orchestration profile — <repo name>

**Repo:** `<org/repo>` · **Default branch:** `<main>` · **Last verified:** `<YYYY-MM-DD>`

> Re-verify before relying on this file. Stale profile entries are the known
> failure mode — a gate command that no longer exists, or a "safe" action that
> became irreversible, is worse than no profile at all.

---

## 1. Gate commands

The exact commands that prove a lane's work. One of these becomes each lane's
acceptance gate in `lanes.json`. **The orchestrator authors the gate; the lane
never does.**

```bash
<setup, e.g. install deps>
<build>
<tests>
<typecheck / static analysis>
<lint>
<domain-specific gate — the one that checks the thing this repo actually cares about>
```

| Command | Exits non-zero on failure? | Currently green? | Notes |
|---|---|---|---|
| `<cmd>` | yes/no | yes/no | <e.g. "baseline is dirty — see below"> |

**Known-bad baselines:** <anything that is red on a clean checkout today, so a
lane doesn't get gated on unrelated debt — or "none">

**What runs automatically:** <CI workflow, hooks, deploy checks — or the honest
answer, "nothing; the orchestrator is the CI">

## 2. The ladder

"Done" is not binary. List this repo's rungs from source to fully released, and
say which rung is the irreversible one.

```
<rung> → <rung> → <rung> → <rung>
```

| Rung | What proves it | Reversible? |
|---|---|---|
| `<rung>` | `<command or observation>` | yes/no |

**The point of no return is `<rung>`** — <why, and what it exposes to whom>.

## 3. Shared aggregators — orchestrator-owned

Files more than one lane would want to edit. Lanes request changes in their
handoff; the orchestrator resolves them **centrally, exactly once**.

- `<path>` — <why it's a hotspot>

**Mandated exceptions** (files lanes MUST touch despite the above, because a repo
rule requires it) — or "none":

- `<path>` — <the rule, and the safe editing discipline, e.g. "append-only under
  a dated heading; never edit another lane's line">

**Known-nasty merges:** <generated files, lockfiles, large committed artifacts —
and the resolution for each, e.g. "regenerate, never hand-merge">

## 4. Irreversible and external actions

The approval-token surface. Anything here needs its own named grant in a lane
brief's §4, and **nothing inherits**.

| Action | Why it's hard to undo | Who approves |
|---|---|---|
| `<action>` | `<consequence>` | `<name>` |

**Hard bans** — things no approval covers:

- <e.g. rewriting published history; weakening a safety guard; a write path that
  bypasses the repo entirely>

## 5. Review lenses

What an independent reviewer should attack *in this repo*. Replace the generic
list — these should be the failure modes this codebase actually has.

1. <lens> — <what to probe, and the command or observation that probes it>
2. …

**Probe, don't read.** For each lens, name the check that would *demonstrate* the
defect, not the file you'd reason about.

## 6. Frozen contracts

The interfaces that convert serial work into concurrent lanes. Freezing these is
what lets lanes start at the same time.

| Artifact | What it fixes | Owner | Consumers |
|---|---|---|---|
| `<path>` | `<the decision it locks>` | `<lane or orchestrator>` | `<lanes>` |

**A change to any of these is an escalation**, ratified by the orchestrator and
fanned out — never a lane editing it quietly, and never a reason for a lane to idle.

---

## Lane boundaries (optional but useful)

Natural disjoint path-scopes in this repo, so the orchestrator isn't inventing
them each time:

- `<glob>` + `<glob>` — <the unit, e.g. one page family / one domain / one service>

## Repo hazards (optional)

Environment-level gotchas a lane will otherwise rediscover:

- <e.g. "only one workspace can run the dev server — port pinned">
- <e.g. "the active CLI account may be the wrong tenant; prefix commands with X">
