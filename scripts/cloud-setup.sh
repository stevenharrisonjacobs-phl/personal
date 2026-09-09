#!/bin/bash
# cloud-setup.sh — SOURCE OF TRUTH for the cloud environment's inline Setup
# script. Paste this file's contents verbatim into the Setup script box at
# claude.ai/code → Environments → spend-checkin.
#
# It must be SELF-CONTAINED. A setup script runs before Claude Code launches,
# provisioning the VM; the platform does not guarantee the repository is
# checked out or that the working directory is the repo root. An earlier
# version delegated to this file with `[ -f scripts/cloud-setup.sh ]`, the
# guard was silently false, and the environment came up with no dependencies
# at all while reporting success (2026-09-09).
#
# Per the docs, repo-dependent setup belongs in a SessionStart hook, not here.
#
# Constraints: exit 0 (non-zero fails the session), finish under ~5 minutes.
# Changing this text invalidates the environment's cached snapshot, which is
# what forces a re-run.

pip install --quiet --disable-pip-version-check \
  'google-cloud-bigquery>=3.25,<4' \
  'langsmith>=0.1,<1' || true

# Verify the IMPORTS rather than pip's exit code. Exiting 0 on failure is
# deliberate — a missing dep must degrade to a named source failure at
# generation time, never a dead morning — but silence is not: without this,
# the setup log reads healthy while two of three collector sources are dark.
missing=""
for mod in langsmith google.cloud.bigquery; do
  python3 -c "import $mod" >/dev/null 2>&1 || missing="$missing $mod"
done
if [ -n "$missing" ]; then
  echo "=====================================================================" >&2
  echo "cloud-setup: DEPENDENCIES MISSING —$missing" >&2
  echo "  BigQuery and/or LangSmith will report as failed sources on EVERY" >&2
  echo "  run. This is a configuration fault, not a transient." >&2
  echo "  Check: network access allows pypi.org + files.pythonhosted.org" >&2
  echo "  (tick 'Also include default list of common package managers')." >&2
  echo "=====================================================================" >&2
else
  echo "cloud-setup: deps ok (langsmith, google-cloud-bigquery)"
fi

exit 0
