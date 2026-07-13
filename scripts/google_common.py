"""Shared helpers for access to personal Google accounts (Gmail + Calendar).

One OAuth *client* (client_secret.json, a Desktop-app credential) authorizes any
number of personal Google *accounts*. Each account is authorized once via a
browser consent flow; its refresh token is stored under .secrets/token-<email>.json
and reused thereafter. Access is read-only for mail (plus draft creation) and
read/write for calendar *events* (see SCOPES below).

Nothing here is specific to a single mailbox: `gmail.py` and `gcal.py` both build
their API clients through `service()` below.
"""
import json
import os
import sys

# Access scopes.
#   gmail.readonly  - read mail.
#   gmail.compose   - CREATE drafts (the `draft` command). We deliberately do NOT
#                     grant a send scope: the tool composes a draft but only you
#                     can send it from Gmail.
#   calendar.readonly - list calendars and read events.
#   calendar.events   - create/edit/DELETE events (the `add` / `delete` commands).
#                     This is event-level write only; it cannot create, delete, or
#                     change sharing on calendars themselves.
# Changing this list invalidates existing tokens: each account must re-authorize
# (scripts/google_auth.py add) before ANY command works again.
SCOPES = [
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/gmail.compose",
    "https://www.googleapis.com/auth/calendar.readonly",
    "https://www.googleapis.com/auth/calendar.events",
]


def repo_root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def reexec_in_venv():
    """Re-run the current script under the repo virtualenv if the Google client
    libraries aren't importable from the current interpreter. Lets the scripts be
    invoked with plain `python3` / `./scripts/gmail.py` and still find their deps."""
    venv_py = os.path.join(repo_root(), ".venv", "bin", "python3")
    if os.path.abspath(sys.executable) == os.path.abspath(venv_py):
        return
    try:
        import googleapiclient  # noqa: F401
    except ModuleNotFoundError:
        if os.path.exists(venv_py):
            os.execv(venv_py, [venv_py, os.path.abspath(sys.argv[0]), *sys.argv[1:]])
        sys.exit(
            "Google client libraries are not installed and no .venv was found.\n"
            "Run: python3 -m venv .venv && "
            ".venv/bin/pip install google-auth google-auth-oauthlib google-api-python-client"
        )


CLIENT_SECRET = os.path.join(repo_root(), "client_secret.json")
SECRETS_DIR = os.path.join(repo_root(), ".secrets")


def _token_path(email):
    return os.path.join(SECRETS_DIR, f"token-{email}.json")


def list_accounts():
    """Authorized account emails, inferred from stored token filenames."""
    if not os.path.isdir(SECRETS_DIR):
        return []
    out = []
    for name in sorted(os.listdir(SECRETS_DIR)):
        if name.startswith("token-") and name.endswith(".json"):
            out.append(name[len("token-"):-len(".json")])
    return out


def _require_client_secret():
    if not os.path.exists(CLIENT_SECRET):
        sys.exit(
            f"Missing {CLIENT_SECRET}\n\n"
            "Create an OAuth client ID (type: Desktop app) in Google Cloud Console\n"
            "(APIs & Services -> Credentials), download the JSON, and save it there."
        )


def authorize():
    """Run the browser consent flow for one account and persist its token.
    Returns the authorized account's email address."""
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build

    _require_client_secret()
    os.makedirs(SECRETS_DIR, exist_ok=True)
    flow = InstalledAppFlow.from_client_secrets_file(CLIENT_SECRET, SCOPES)
    # access_type=offline + prompt=consent guarantees a refresh token so we never
    # have to re-prompt on future runs.
    creds = flow.run_local_server(
        port=0,
        access_type="offline",
        prompt="consent",
        authorization_prompt_message=(
            "Opening your browser to authorize. If it doesn't open, visit:\n{url}"
        ),
        success_message="Authorized. You can close this tab and return to the terminal.",
    )
    # Identify which account was authorized so we can name the token file.
    profile = build("gmail", "v1", credentials=creds, cache_discovery=False) \
        .users().getProfile(userId="me").execute()
    email = profile["emailAddress"]
    with open(_token_path(email), "w") as f:
        f.write(creds.to_json())
    os.chmod(_token_path(email), 0o600)
    return email


def load_credentials(email):
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials

    path = _token_path(email)
    if not os.path.exists(path):
        sys.exit(f"No token for {email}. Authorize it first: scripts/google_auth.py add")
    creds = Credentials.from_authorized_user_file(path, SCOPES)
    if not creds.valid:
        if creds.expired and creds.refresh_token:
            creds.refresh(Request())
            with open(path, "w") as f:
                f.write(creds.to_json())
        else:
            sys.exit(f"Token for {email} is invalid; re-authorize: scripts/google_auth.py add")
    return creds


def service(api, version, email):
    """Build a Google API client for one account (api='gmail'|'calendar')."""
    from googleapiclient.discovery import build
    return build(api, version, credentials=load_credentials(email), cache_discovery=False)


def resolve_accounts(selector):
    """Turn a --account selector into a concrete list of authorized emails.
    None/"all" -> every account; otherwise a substring match on the email."""
    accounts = list_accounts()
    if not accounts:
        sys.exit("No accounts authorized yet. Run: scripts/google_auth.py add")
    if not selector or selector == "all":
        return accounts
    matches = [a for a in accounts if selector.lower() in a.lower()]
    if not matches:
        sys.exit(f"No authorized account matches '{selector}'. Known: {', '.join(accounts)}")
    return matches
