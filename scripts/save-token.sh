#!/usr/bin/env bash
# save-token.sh — prompt for a provisioning token and store it safely.
#
# Tokens go to .secrets/ (gitignored) with 0600, never to the terminal, never
# to shell history, and never with a trailing newline — a stored "\n" is the
# classic silent auth failure: the value looks right in every dump you make of
# it, and the API rejects it with an error that never mentions whitespace.
#
# Usage:  ./scripts/save-token.sh mercury|vantage|langsmith|apify
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="$ROOT_DIR/.secrets"

case "${1:-}" in
  mercury)   FILE=mercury.token;   ENVVAR=MERCURY_API_TOKEN;  SCOPE="READ-ONLY (no IP allowlist prompt)" ;;
  vantage)   FILE=vantage.token;   ENVVAR=VANTAGE_API_TOKEN;  SCOPE="Read only" ;;
  langsmith) FILE=langsmith.key;   ENVVAR=LANGSMITH_API_KEY;  SCOPE="fresh key, Snapfix + Snapfix-Agents workspace" ;;
  apify)     FILE=apify.token;     ENVVAR=APIFY_API_TOKEN;    SCOPE="scoped: read actor runs only" ;;
  *)
    echo "Usage: $0 mercury|vantage|langsmith|apify" >&2
    exit 2 ;;
esac

DEST="$SECRETS_DIR/$FILE"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

if [ -e "$DEST" ]; then
  printf 'A token already exists at .secrets/%s. Replace it? [y/N] ' "$FILE"
  read -r reply
  case "$reply" in [yY]*) ;; *) echo "Kept the existing token."; exit 0 ;; esac
fi

echo "Source:   $1"
echo "Expected: $SCOPE"
echo "Maps to:  \$$ENVVAR in the cloud environment"
echo
printf 'Paste the token (input hidden), then Enter: '
IFS= read -rs TOKEN
echo

# Trim surrounding whitespace: a copy from a web console often carries a
# trailing space or newline that is invisible on paste.
TOKEN="${TOKEN#"${TOKEN%%[![:space:]]*}"}"
TOKEN="${TOKEN%"${TOKEN##*[![:space:]]}"}"

if [ -z "$TOKEN" ]; then
  echo "Empty — nothing written." >&2
  exit 1
fi
# Interior whitespace means a wrapped or partial paste, never a real token.
case "$TOKEN" in
  *[[:space:]]*)
    echo "That value contains a space or line break inside it, which no token has." >&2
    echo "Likely a wrapped or partial paste. Nothing written — try again." >&2
    exit 1 ;;
esac

# printf %s, not echo: no trailing newline. umask so the file is never even
# briefly world-readable between creation and chmod.
( umask 077; printf %s "$TOKEN" > "$DEST" )
chmod 600 "$DEST"

# Confirm WITHOUT revealing the value: length plus a short digest prefix is
# enough to tell two tokens apart, or to match against the console, and
# discloses nothing usable.
LEN=${#TOKEN}
FP=$(printf %s "$TOKEN" | shasum -a 256 | cut -c1-8)
unset -v TOKEN

echo "Saved .secrets/$FILE  (${LEN} chars, sha256:${FP}…, mode $(stat -f '%Lp' "$DEST"))"
echo "Nothing was echoed, and .secrets/ is gitignored."
