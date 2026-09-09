#!/usr/bin/env bash
# cloud-setup.sh — claude.ai/code cloud-environment setup script for the
# spend check-in routines. Runs on every fresh VM (results cached ~7 days).
# Must exit 0 fast; a failed dependency shows up as a failed SOURCE at
# generation time (named in errors[]), never a dead morning.
#
# The sandbox ships Python 3 + pip but no gcloud/bq CLI — deliberate: the
# cloud path is door-native for finance reads/writes and pure-Python for the
# collector (KTD6 in the plan; docs/runbooks/cloud-checkin.md).
set -u

python3 -m pip install --quiet --disable-pip-version-check \
  'google-cloud-bigquery>=3.25,<4' \
  'langsmith>=0.1,<1' || echo "cloud-setup: pip install failed ($?)" >&2

# Verify the IMPORTS, not pip's exit code. Exiting 0 on a failed install is
# deliberate (a missing dep must degrade to a named source failure at
# generation time, never a dead morning) — but silence is not. Without this
# check the setup log looks healthy while two of three collector sources are
# dead every single run, which is exactly what happened on 2026-09-09: the
# environment's egress allowlist omitted pypi.org, pip could not reach the
# index, and nothing said so until the collector's errors[] was read by hand.
missing=""
for mod in langsmith google.cloud.bigquery; do
  python3 -c "import $mod" >/dev/null 2>&1 || missing="$missing $mod"
done
if [ -n "$missing" ]; then
  echo "=======================================================================" >&2
  echo "cloud-setup: DEPENDENCIES MISSING —$missing" >&2
  echo "  Every run in this environment will report BigQuery and/or LangSmith" >&2
  echo "  as failed sources. This is a CONFIGURATION fault, not a transient." >&2
  echo "  Most likely: the environment's network access is Custom WITHOUT" >&2
  echo "  'Also include default list of common package managers', so pypi.org" >&2
  echo "  and files.pythonhosted.org are not reachable. Fix the allowlist and" >&2
  echo "  start a fresh session (setup results are cached ~7 days)." >&2
  echo "=======================================================================" >&2
else
  echo "cloud-setup: deps ok (langsmith, google-cloud-bigquery)"
fi

# Scratch dir for raw pulls (gitignored; ephemeral with the VM).
mkdir -p .context/checkin || true

exit 0
