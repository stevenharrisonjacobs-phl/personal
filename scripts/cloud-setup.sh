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

# Scratch dir for raw pulls (gitignored; ephemeral with the VM).
mkdir -p .context/checkin || true

exit 0
