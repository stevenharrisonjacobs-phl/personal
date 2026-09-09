---
title: "Cloud Run :latest secrets cause split-brain auth after rotation"
date: 2026-09-09
category: integration-issues
module: door/deploy
problem_type: integration_issue
component: infrastructure
symptoms:
  - "Intermittent 401s from a Cloud Run service after rotating a secret, with no error naming rotation"
  - "The same bearer token is accepted by one request and refused by the next"
  - "Retrying 'fixes' it, so the failure looks like a flaky network rather than a config change"
root_cause: config_error
resolution_type: config_change
severity: high
tags: [cloud-run, secret-manager, rotation, authentication, deploy]
---

# Cloud Run :latest secrets cause split-brain auth after rotation

## Problem

The personal door mounted its machine-token digests as
`--set-secrets PERSONAL_DOOR_MACHINE_TOKEN_DIGESTS=...:latest`. Rotating the
machine tokens then put the service into a state where the *same* caller token
was accepted or rejected depending on which instance answered — intermittently,
with nothing in the logs connecting the 401s to the rotation that caused them.

## Symptoms

- Machine callers get 401s from some requests and 200s from others, same token.
- The failure rate drifts down over minutes or hours with no deploy.
- Nothing in the service logs mentions secrets, versions, or rotation.

## What Didn't Work

- **Reasoning about it as a deploy-time binding.** The mental model that
  `--set-secrets NAME:latest` is resolved once, when `gcloud run deploy`
  runs, is the whole bug. Under that model rotation looks safe: "the next
  deploy picks it up." No deploy is involved.
- **Treating it as a token-minting bug.** The digests were minted correctly and
  the verifier compared them correctly. Both sides were right; they were
  looking at different *versions* of the same secret.

## Solution

Resolve the concrete version at deploy time and pin it, so a revision's
configuration is immutable:

```bash
# scripts/deploy-door.sh, candidate stage
pin() { # pin NAME -> appends NAME=NAME:<n> to $secret_args
  local name="$1" version
  version=$(gc secrets versions describe latest --secret "$name" \
              --project "$PROJECT" --format='value(name)' 2>/dev/null \
            | sed 's#.*/##' || true)
  case "$version" in
    ''|*[!0-9]*)
      echo "Could not resolve a version for secret $name." >&2
      echo "Run: $0 secrets" >&2
      exit 1 ;;
  esac
  secret_args="${secret_args:+$secret_args,}${name}=${name}:${version}"
}
```

Then rotation becomes an ordered deploy rather than an ambient event, and the
runbook says so: `rotate-tokens` → `build` → `candidate` → `probe` →
`promote`.

## Why This Works

Cloud Run resolves secret environment variables **when an instance starts**,
not once per deployment
([docs](https://docs.cloud.google.com/run/docs/configuring/services/secrets)).
With `:latest`, every cold start is an independent re-resolution, so after a
new secret version lands, warm instances keep serving the old value while newly
started ones serve the new one. For a *credential* that is not a stale-cache
annoyance — it is two populations of instances disagreeing about which
credentials are valid, for as long as the old instances stay warm.

Pinning an explicit version removes the ambient variable. A revision now has
exactly one answer, adding a secret version changes nothing until a new
revision is promoted, and the cutover is a traffic shift — observable, ordered,
and reversible by rolling back traffic.

Pinning does not make rotation free; it makes the cost **visible and bounded**.
Callers that read the raw token at `:latest` pick up a new token the instant it
is minted, while the live revision still pins the old digests, so there is a
deterministic 401 window between minting and promote. That window is
documented rather than designed away — closing it fully needs the digest map to
carry old and new digests per identity, which is an auth-schema change.

## Prevention

- **Never mount a secret as `:latest` when its value is a credential the
  service compares against.** `:latest` is defensible for a value where a mixed
  fleet is harmless; it is never defensible for an authenticator.
- **Ask "resolved when?" of every late-bound reference in a deploy**, not
  "resolved to what?". The dangerous ones resolve per instance, per request, or
  per cold start — not per deploy.
- **Make the deploy fail loudly when a version cannot be resolved.** The `pin`
  helper appends to a variable rather than printing into
  `"$(pin a),$(pin b)"`: in the latter shape the exit status is only the *last*
  substitution's, so a silently empty first element ships a malformed
  `--set-secrets` instead of aborting.
- **Verify with a stub.** Faking `gcloud` on `PATH` proved both that the
  deploy sends `NAME=NAME:7` and that an unresolvable secret exits 1 before any
  `run deploy` — no cloud project touched.

## Related Issues

- `scripts/deploy-door.sh` — the `candidate` stage pins; `rotate-tokens` owns
  the cutover ordering.
- `docs/runbooks/cloud-checkin.md` — the operator-facing rotation sequence and
  its 401 window.
- Same fix pass: rotation had a second defect — a setup stage that regenerated
  every secret on each run, so rotating tokens also destroyed OAuth state. See
  `docs/solutions/conventions/setup-stages-create-if-absent.md`.
