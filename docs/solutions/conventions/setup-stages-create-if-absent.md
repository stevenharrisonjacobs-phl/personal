---
title: "Setup stages create if absent; rotation is always its own stage"
date: 2026-09-09
category: conventions
module: door/deploy
problem_type: convention
component: infrastructure
symptoms:
  - "Re-running a setup script to rotate one credential silently regenerates unrelated ones"
  - "Every issued session token is invalidated by a command that was only meant to mint a new API token"
  - "Encrypted records become permanently unreadable after a routine re-run"
root_cause: config_error
resolution_type: workflow_improvement
severity: high
applies_when:
  - "A single setup stage provisions several secrets or keys with different blast radii"
  - "An operator is told a stage is idempotent, or infers it because re-running is normal"
tags: [secrets, rotation, idempotence, deploy, encryption]
---

# Setup stages create if absent; rotation is always its own stage

## Context

`scripts/deploy-door.sh secrets` provisioned four things in one stage: the
Google OAuth client secret, `JWT_SIGNING_KEY`, `STORAGE_ENCRYPTION_KEY` (a
Fernet key encrypting OAuth records in Firestore), and three machine tokens
plus their digest map. It wrote a **new version of every one of them on every
run**, and its own help text advertised that as the rotation path: "Re-running
ROTATES the machine tokens."

It does — and it also throws away the JWT signing key and the Fernet key.
Rotating a machine token therefore invalidated every issued JWT and rendered
every Firestore record encrypted under the previous Fernet key permanently
unreadable. The stage was doing exactly what it said, and what it said was a
trap: the operator's stated intent ("rotate a token") and the command's blast
radius ("regenerate all cryptographic state") had nothing to do with each
other.

## Guidance

**A setup stage is create-if-absent. Rotation is a separate, named stage. A
credential whose rotation is destructive gets no rotation stage at all.**

```bash
put_if_absent() { # put_if_absent NAME < value-on-stdin
  local name="$1"
  if have "$name"; then
    cat >/dev/null            # drain the pipe; the new value is discarded
    echo "  $name — exists, left alone"
  else
    gc secrets create "$name" --data-file=- --project "$PROJECT" >/dev/null
    echo "  $name — created"
  fi
}
```

Three rules fall out of it:

1. **Re-running setup changes nothing that already exists.** This is what
   makes a provisioning runbook safe to follow twice — during a partial
   failure, that is the operator's first instinct.
2. **Each rotation gets its own stage, scoped to one credential family.**
   `rotate-tokens` touches the machine tokens and nothing else;
   `rotate-oauth-secret` touches the OAuth client secret and nothing else.
3. **Where rotation is destructive without a migration, ship no stage and say
   why.** `JWT_SIGNING_KEY` and `STORAGE_ENCRYPTION_KEY` have no rotation
   command, and the script and spec both state that rotating the Fernet key
   without a re-encrypt migration is data loss, not rotation. An absent
   capability with a stated reason is a design decision; an absent capability
   with no comment reads as an oversight and invites someone to add it.

Drain the discarded stdin (`cat >/dev/null`). A generator upstream in the pipe
(`openssl rand ... | put_if_absent NAME`) gets SIGPIPE otherwise, and under
`set -o pipefail` that aborts the stage for a no-op.

## Why This Matters

Bundling provisioning and rotation makes blast radius a function of *what the
stage happens to contain* rather than *what the operator asked for*. That
coupling is invisible at the call site — `deploy-door.sh secrets` names none of
the four things it will overwrite — and it fails at the worst moment, because
rotation is usually reached for under pressure (a suspected leak, an expiring
credential, an incident).

The asymmetry is what makes it worth a rule rather than a judgment call:
creating a secret that already exists is harmless, while overwriting one may
be unrecoverable. Defaulting to create-if-absent costs a separate stage;
defaulting to overwrite costs whatever the worst credential in the bundle is
protecting.

## When to Apply

- Any script that provisions more than one secret, key, or credential.
- Any stage an operator is expected to re-run — which, in practice, is every
  stage in a provisioning runbook.
- Whenever a comment or help string is about to describe a side effect as the
  supported way to do something ("re-running rotates X"). If the side effect is
  worth documenting, it is worth its own command.

## Examples

Before — one stage, four blast radii, rotation as a side effect:

```bash
secrets)
  printf %s "$CLIENT_SECRET" | put GOOGLE_OAUTH_CLIENT_SECRET
  openssl rand -base64 48 | tr -d '\n' | put JWT_SIGNING_KEY
  openssl rand 32 | base64 | tr '+/' '-_' | tr -d '\n' | put STORAGE_ENCRYPTION_KEY
  mint CHECKIN_ROUTINE; ...        # `put` always adds a new version
```

After — `secrets` provisions, `rotate-tokens` rotates, the Fernet key has no
rotation path:

```bash
secrets|rotate-tokens|rotate-oauth-secret)
  ...
  rotate-tokens)
    have PERSONAL_DOOR_MACHINE_TOKEN_DIGESTS \
      || { echo "No machine tokens exist yet. Run: $0 secrets" >&2; exit 1; }
    read -r -p "Type the project id to continue: " confirm
    [ "$confirm" = "$PROJECT" ] || { echo "Mismatch. Nothing done." >&2; exit 1; }
    mint_all add_version
    ;;
  esac
  # --- stage: secrets (create-if-absent) ---
  openssl rand -base64 48 | tr -d '\n' | put_if_absent JWT_SIGNING_KEY
```

The writer is passed in (`mint_all add_version` vs `mint_all put_if_absent`),
so both stages share one minting implementation and differ only in whether an
existing secret may be overwritten.

## Related

- `scripts/deploy-door.sh` — the split stages.
- `docs/solutions/integration-issues/cloud-run-latest-secret-split-brain.md` —
  the other half of the same rotation story: pinning secret versions so
  rotation is an ordered deploy rather than an ambient event.
- `docs/runbooks/cloud-checkin.md` — the operator sequence both docs feed.
