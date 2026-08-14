---
name: harness
description: Triage a task into solo / fan-out / program, and instantiate this repo's harness (context file, orchestration profile, task graph) — idempotently. Use at the start of work in any repo, when Steven says "harness", "set this repo up", "should this be a program?", "triage this", or when a SessionStart report says something is missing or has drifted.
---

# The harness

Two jobs: **decide the shape of the work**, and **make sure this repo has what
that shape needs.** Both are cheap. Neither is a project.

## 1. Triage — always, before the first action

The rubric is in `~/.claude/CLAUDE.md` and loads in every session; this is what
to *do* with each verdict.

### Question 1 — can this be undone?

**Reversible** (edits, branches, local commits, dry runs, read-only queries):
proceed. Reversibility is what buys the right to act without asking.

**Irreversible** — production DDL, deploys, scheduler changes, release flags,
external sends, publishing, anything that leaves the machine: **prepare, verify,
and stop.** Hand Steven the exact command and the evidence it is safe. Say
plainly what you are stopping before. This holds at any size: a one-line change
can be irreversible, and it does not become reversible because it is small.

If any *step* is irreversible, the task is irreversible. Do the reversible parts,
then stop at the boundary — do not treat "mostly safe" as safe.

### Question 2 — how many write-scopes?

A write-scope is the set of files something will edit. Count scopes, not tasks.

| Verdict | When | What it looks like |
|---|---|---|
| **Solo** | one scope, or the work is small | Just do it. No ceremony, no bus, no branch theatre. **This is the default and most work lands here.** |
| **Fan out** | several scopes that do not overlap | One session, concurrent subagents, results return to you. No program bus. Reads, research, per-item work, independent files. |
| **Program** | overlapping scopes **and** real judgment **and** something irreversible | `/orchestrate`. Frozen contracts, lanes, gates, independent review, central integration. |

**Diff the scopes before fanning out.** Overlap collapses into one worker even
when the tasks sound independent — three edits to one file cluster merge cleanly
and still break, because a rename in one is invisible to the textual merge of
the others. Unblocked is not the same as parallelizable.

**Bias hard toward solo.** Over-orchestration is a well-documented waste source,
and the ceiling on useful parallelism is Steven's review capacity, not compute.
Ten finished agents waiting on review is pressure, not progress. If the verdict
is "program," say why in one sentence — that sentence is the justification, and
if you cannot write it, it is not a program.

**State the verdict in one line and move.** "Solo, reversible." is a complete
triage. Only escalations need explaining.

## 2. Instantiate — only what is missing

```bash
bash ~/.claude/skills/harness/scripts/harness-doctor.sh --verbose
```

Read-only. It reports the three per-repo artifacts and the remedy for each gap.
Then fill only the gaps, and only the ones the work actually needs:

| Gap | Remedy | Needed when |
|---|---|---|
| context file | `/init` | always — every repo earns a `CLAUDE.md` |
| `orchestration/PROFILE.md` | `bash ~/.claude/skills/orchestrate/scripts/orch-adopt.sh` | the repo has irreversible actions worth naming |
| `.beads/` | `bd init` — **ask first, see below** | work spans more than one session or one agent |

**`bd init` is not a small footprint, so a script never runs it for you.** It
creates `.beads/` *and* `.agents/`, `.claude/`, `.codex/`, `.cursor/`, a
`.gitignore`, and it **appends a beads block to `CLAUDE.md` and `AGENTS.md`**.
The append is non-destructive — marked block, prior content preserved — but in a
repo where `CLAUDE.md` is governed content, a setup step editing it unasked is
exactly the surprise this harness exists to prevent, and no flag suppresses it.
Show Steven that list, then run it. Use `--init-if-missing` to keep it
idempotent.

A `CLAUDE.md` that contains *only* the beads block is a stub, not repo context —
the doctor says so, and `/init` is still owed.

**A repo with nothing irreversible and no multi-step work needs only a context
file.** Do not scaffold a profile into a static site to be thorough; an unfilled
profile is worse than none, because it looks like an answer.

The profile is filled **by measuring** — run the commands, read the config, hit
the live system — and §4 (irreversible actions) is a conversation with Steven,
never a guess. It names what cannot be undone.

## 3. Drift — the reason this is a skill and not a memory

Per-repo files are copies. When the shape changes, the copies do not, and
nothing says so. The doctor stamps and checks:

- **Schema** — `PROFILE.md` carries `**Harness schema:** N`. When the template
  gains a section, `CURRENT_SCHEMA` in the doctor script goes up and every older
  profile reports the gap on its next session. Patch it when you are next in
  that repo; do not run a nine-repo migration.
- **Staleness** — a profile whose `Last verified` is over 90 days old is
  reported. A stale gate command, or an action that quietly became irreversible,
  is worse than no profile: it tells an operator a dangerous thing is cheap.

## Where things live — the rule that keeps this to one edit

**Shape is global. Answers are per-repo.**

- **Global** (`~/.claude/`, version-controlled in `conductor/repos/personal`):
  the skills, `CLAUDE.md`, the `SessionStart` hook. Change the triage, a lane
  rule, an invariant → **one edit, every repo has it.**
- **Per-repo** (committed there): `orchestration/PROFILE.md`, `CLAUDE.md`,
  `.beads/`. Nine repos legitimately have nine different answers.

The test: if you would edit the same paragraph in more than one repo, it is
shape — move it into the skill. Never edit a repo to change the harness.
