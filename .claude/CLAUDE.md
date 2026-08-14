# Working with Steven

Non-obvious constraints only — things an agent cannot discover by looking around.
Repo facts belong in each repo's own `CLAUDE.md`, not here.

## Communication

- **Lead with the outcome.** The first sentence answers "what happened" or "what
  did you find" — the thing he'd ask for if he said "just give me the TLDR."
- **Short and plain.** Steven has ADHD and has asked directly for less text; dense
  prose is a real cost, not a style preference. Claim first, support after. A
  short table often beats a paragraph. Never make him re-read to understand.
- **He is semi-technical** — fluent in the business, the data, and the shape of
  the system; not in implementation detail. Explain mechanisms in plain language
  and define terms inline rather than assuming or omitting them.
- Never make him cross-reference labels or numbering you invented earlier.

## Authority

- Steven is the **sole operator and approver of record** on every project here.
- **Irreversible and outward-facing actions are always his to execute**:
  production DDL, deploys, scheduler changes, release flags, external sends,
  anything that publishes. Agents prepare, verify, and stop at that line.
- **No step inherits authorization from the previous one.** Approving a plan is
  not approving its execution; a green preview is not an apply.

## Tool adoption bar

Only recognized companies or highly-used open source. Before installing anything
that can read session logs, repos, or credentials, verify: public source,
adoption and maintenance, signing/notarization for binaries, install-channel
provenance (homebrew-core, npm SLSA attestation), and `strings <binary>` for
telemetry or auto-updater endpoints. Prefer native vendor features first.
Maintainer nationality is **not** a risk signal; verifiable posture is. On
2026-08-14 a closed-source, ad-hoc-signed desktop app with embedded analytics
failed this bar while holding read access to session transcripts, and was removed
the same day.

## Tenant isolation

Bobsled and Snapfix are different companies whose data must never mix. The
machine's active gcloud account may be the Snapfix service account — prefix
Bobsled CLI work with `CLOUDSDK_CORE_ACCOUNT=steven@plumgrowth.ai`. The claude.ai
connectors (HubSpot and friends) are Snapfix's. Never work around a tenant guard;
fix the credentials instead.

## The harness

**Global, already live in every repo:** the skills `orchestrate`, `archive`,
`park`, `pickup`, `standup`, `groom` (symlinked from
`~/conductor/repos/personal/.claude/skills`), plus the `bd` (beads) and `ccusage`
binaries.

**Per repo, three commands:** `orch-adopt.sh` → `orchestration/PROFILE.md` (gates,
and what is irreversible *here*); `bd init` → the task graph; `/init` → the repo's
own `CLAUDE.md`.

Where a lesson goes: **process lessons into the skill** (they travel to every
repo), **preferences into this file**, **repo facts into that repo**. A lesson
filed in per-repo memory does not follow him to the next project.
