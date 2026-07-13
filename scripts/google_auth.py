#!/usr/bin/env python3
"""Authorize personal Google accounts (read Gmail, read/write Calendar events).

Uses one Desktop-app OAuth client (client_secret.json at the repo root) to
authorize any number of accounts. Run `add` once per account; a browser opens
for consent and the resulting token is stored under .secrets/. Re-run `add` for
an already-authorized account to refresh its granted scopes (e.g. after the
SCOPES list in google_common.py changes) — pick the same account in the browser
and it overwrites the stored token.

    scripts/google_auth.py add       # authorize/re-authorize an account (opens browser)
    scripts/google_auth.py list      # show authorized accounts
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import google_common as g  # noqa: E402

g.reexec_in_venv()


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "add":
        print("Starting Google authorization. A browser window will open for consent.")
        email = g.authorize()
        print(f"\n✓ Authorized {email}")
        print(f"Authorized accounts: {', '.join(g.list_accounts())}")
    elif cmd == "list":
        accounts = g.list_accounts()
        if not accounts:
            print("No accounts authorized yet. Run: scripts/google_auth.py add")
        else:
            print("Authorized accounts:")
            for a in accounts:
                print(f"  - {a}")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
