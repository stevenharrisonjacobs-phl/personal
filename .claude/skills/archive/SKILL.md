---
name: archive
description: Safely archive the current Conductor workspace — commit & push all work, write a durable handoff/changelog so someone can understand the work cold, and capture the session transcripts for later debugging. Use when the user says "archive this workspace", "/archive", "wrap up and archive", or is about to delete/archive a Conductor worktree.
---

# Archive a Conductor workspace

When a Conductor workspace is archived, its git **worktree is deleted**. Only two
things survive that deletion:

1. The **branch** — but only if it was pushed to the remote.
2. The **session transcripts** at `~/.claude/projects/<slug>/*.jsonl` — but that
   folder is keyed by the workspace *path*, and Conductor reuses city names, so a
   future workspace can orphan or co-mingle them.

Anything in the worktree that isn't committed+pushed, and any context that lives
only in `.context/` (which is **gitignored**), is **lost forever**. This skill's
job is to make sure nothing important is lost and that the next person — human or
agent — can understand and resume the work.

Work through the steps in order. Confirm with the user before any irreversible or
outward-facing action (commits, pushes, PR creation). Do **not** archive the
workspace in Conductor yourself — that's the user's action in the app; you prepare
everything so it's safe to do.

## 1. Preflight — assess state, don't change anything yet

Run and report back concisely:

```bash
git rev-parse --abbrev-ref HEAD                    # current branch
git status --short                                 # uncommitted changes
git log --oneline origin/main..HEAD                # unpushed / branch-only commits
git rev-list --left-right --count origin/main...HEAD   # behind<TAB>ahead
gh pr list --head "$(git rev-parse --abbrev-ref HEAD)" --json number,title,state 2>/dev/null
ls -A .context/ 2>/dev/null                        # gitignored scratch that would be LOST
```

Tell the user in one summary: branch, how many uncommitted files, how many unpushed
commits, whether a PR exists, and whether `.context/` holds anything that looks
worth preserving (it will be deleted with the worktree). If `.context/` has
artifacts the work depends on, flag them and ask whether to copy any into the
committed handoff or the external archive dir.

## 2. Capture session transcripts (do this FIRST — before any branch work)

Run the helper **before** committing/pushing or creating branches. Two reasons:
the archive run may create throwaway branches (to split unrelated loose ends into
separate PRs), and if you switch to a branch that doesn't have this skill checked
out, the script file disappears from the working tree. Capturing first sidesteps
both. Invoke it by the skill's **base directory absolute path** (given at the top
of these instructions), not a repo-relative path, so it resolves regardless of the
checked-out branch:

```bash
bash "<skill-base-dir>/scripts/collect-transcripts.sh"
# preview first with:  DRY_RUN=1 bash "<skill-base-dir>/scripts/collect-transcripts.sh"
```

- Copies every `~/.claude/projects/<slug>/*.jsonl` to
  `<ARCHIVE_ROOT>/<workspace>-<date>/transcripts/` (never-reused, date-stamped).
- Emits a `## Session transcripts` manifest (session IDs, message counts,
  timestamps, branch-at-capture). **Keep that manifest** — you'll paste it into the
  handoff in step 5.

Transcripts are read-only snapshots, so capturing now (rather than at the very end)
only misses the last few mechanical messages of the archive run itself — negligible.
If the helper prints `NO_TRANSCRIPTS`, note that in the handoff and continue.

Steps 3 and 4 are **checks first**. Preflight often shows the work is already
committed and pushed (e.g. the user finished and merged earlier) — in that case
these are no-ops: confirm the state and move on. Only act when something is
actually outstanding.

## 3. Ensure work is committed (check, then act only if dirty)

Preflight's `git status --short` already told you. If **clean**, say "working tree
clean, nothing to commit" and skip. If **dirty**:
- Review the diff so the commit message is accurate (`git diff --stat` then spot-check).
- Propose a commit message; get the user's OK.
- Stage and commit. Follow repo commit conventions (see root `CLAUDE.md`), and end the
  message with the required `Co-Authored-By` trailer.

## 4. Ensure the branch is pushed (check, then act only if ahead)

Preflight's `origin/main..HEAD` + PR list already told you. If the branch is
**already on the remote and not ahead**, confirm "branch already pushed, up to
date" and skip. If there are **unpushed commits**:

```bash
git push -u origin "$(git rev-parse --abbrev-ref HEAD)"
```

Confirm the push succeeded. If push is rejected (diverged), stop and resolve with
the user — never force-push without explicit approval.

## 5. Write the handoff / changelog

This is the "so someone can easily understand the work" deliverable. Use the
template at `templates/ARCHIVE.md` in this skill dir. Fill every section with real
content — the goal, the approach, the outcome, key files, current state, next
steps, and how to resume. Write for someone who was never in the loop. **Append the
`## Session transcripts` manifest from step 2** to it.

**Where it goes** (pick based on how the work will live on):

- **If there's a PR (or you create one):** the PR description is the primary,
  durable, reviewable home. Put the filled-in handoff there
  (`gh pr edit <n> --body-file ...` or `gh pr create`). This is the default for
  branch work headed to `main`.
- **Always also write a committed copy** at `docs/archive/<YYYY-MM-DD>-<branch-slug>.md`
  so the record travels with the branch/PR and survives even if the PR is closed.
  (Mirrors the repo's existing `docs/HANDOFF-*.md` convention.)
- **If the work is being abandoned** (no PR, won't merge): still commit the
  `docs/archive/...` copy and push, so the reasoning isn't lost.

Never put the canonical handoff only in `.context/` — it's gitignored and dies with
the worktree. Also drop a copy of the finished handoff into the archive dir from
step 2, alongside the transcripts, so the session and its explanation live together.

### Reaching archives from either machine

Two halves, two homes:

- **The handoff docs are already cross-machine** once committed + pushed — GitHub
  serves `docs/archive/...` and the PR body to either Mac. That satisfies "reach
  these docs on either machine" with no extra step.
- **The raw transcripts** only exist on the Mac that ran the session. The helper
  defaults `ARCHIVE_ROOT` to **iCloud Drive** (`~/Library/Mobile
  Documents/com~apple~CloudDocs/conductor-archives/`) when present, so they sync to
  the other Mac automatically *if both machines use the same Apple ID*.
  - If the two Macs use **different Apple IDs**, or you want access-controlled /
    team-reachable storage, push to GCS instead of relying on iCloud:
    ```bash
    gsutil -m cp -r "<archive dest>" gs://<bucket>/conductor-archives/
    ```
    (project `annular-weaver-496320-a9`; create the bucket once). Record the
    `gs://` path in the handoff so it's findable from any machine.
- Do **not** commit raw transcripts to git — they can contain secrets echoed in
  tool output, and that's permanent in history.

## 6. Final report

Give the user a short checklist of what is now durable and where:

- ✅ committed + pushed — branch `X` on origin (or ⚠️ if anything couldn't be pushed)
- ✅ handoff at `docs/archive/...` and/or PR #N
- ✅ N session transcripts at `<ARCHIVE_ROOT>/<workspace>-<date>/` (iCloud Drive by default → syncs to the other Mac)
- ⚠️ anything in `.context/` that will be lost (list it, or confirm nothing of value)

End with: **"Safe to archive the workspace in Conductor now."** — or, if anything
above failed, say clearly what's still at risk and don't give the all-clear.
