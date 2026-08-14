#!/usr/bin/env python3
"""Personal Spotify Web API client (OAuth Authorization Code flow, stdlib only).

One-time setup:
  1. Create an app at https://developer.spotify.com/dashboard
     - Redirect URI (exact):  http://127.0.0.1:8888/callback
     - APIs used: "Web API"
  2. Put the credentials in .env at the repo root:
       SPOTIFY_CLIENT_ID=...
       SPOTIFY_CLIENT_SECRET=...
  3. Run `scripts/spotify.py auth` once — a browser opens for consent; the
     resulting refresh token is stored under .secrets/ (gitignored) and reused
     silently thereafter. No further logins.

Commands:
  scripts/spotify.py auth               authorize (opens browser, stores token)
  scripts/spotify.py top [range] [n]    top artists (range: short|medium|long, default medium; n<=50)
  scripts/spotify.py recent [n]         recently-played artists (n<=50)
  scripts/spotify.py following          followed artists
  scripts/spotify.py artists            union of the above, deduped (the "taste graph")
"""
import base64
import http.server
import json
import os
import sys
import threading
import urllib.parse
import urllib.request
import webbrowser

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOKEN_PATH = os.path.join(REPO, ".secrets", "spotify_token.json")
REDIRECT_URI = "http://127.0.0.1:8888/callback"
SCOPES = "user-top-read user-read-recently-played user-follow-read user-library-read"
AUTH_URL = "https://accounts.spotify.com/authorize"
TOKEN_URL = "https://accounts.spotify.com/api/token"
API = "https://api.spotify.com/v1"


def _load_env():
    """Minimal .env loader so we don't depend on python-dotenv."""
    path = os.path.join(REPO, ".env")
    if os.path.exists(path):
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def _creds():
    _load_env()
    cid = os.environ.get("SPOTIFY_CLIENT_ID")
    secret = os.environ.get("SPOTIFY_CLIENT_SECRET")
    if not cid or not secret:
        sys.exit(
            "Missing SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET.\n"
            "Add them to .env at the repo root (see this file's docstring)."
        )
    return cid, secret


def _post_token(data):
    cid, secret = _creds()
    basic = base64.b64encode(f"{cid}:{secret}".encode()).decode()
    body = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(
        TOKEN_URL,
        data=body,
        headers={
            "Authorization": f"Basic {basic}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        sys.exit(f"Token request failed ({e.code}): {e.read().decode()}")


def _save_token(tok):
    os.makedirs(os.path.dirname(TOKEN_PATH), exist_ok=True)
    with open(TOKEN_PATH, "w") as fh:
        json.dump(tok, fh, indent=2)


def authorize():
    cid, _ = _creds()
    params = urllib.parse.urlencode(
        {
            "client_id": cid,
            "response_type": "code",
            "redirect_uri": REDIRECT_URI,
            "scope": SCOPES,
        }
    )
    url = f"{AUTH_URL}?{params}"
    code_holder = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.urlparse(self.path).query
            params = urllib.parse.parse_qs(q)
            code_holder["code"] = params.get("code", [None])[0]
            code_holder["error"] = params.get("error", [None])[0]
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            msg = "Spotify authorized — you can close this tab and return to the terminal."
            if code_holder.get("error"):
                msg = f"Authorization error: {code_holder['error']}"
            self.wfile.write(f"<html><body><h3>{msg}</h3></body></html>".encode())

        def log_message(self, *a):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 8888), Handler)
    print("Opening browser for Spotify consent...")
    print(f"If it doesn't open, paste this URL:\n  {url}\n")
    webbrowser.open(url)
    threading.Thread(target=server.handle_request).start()
    # handle_request serves exactly one request (the redirect), then returns.
    import time

    for _ in range(120):
        if code_holder:
            break
        time.sleep(1)
    server.server_close()
    if code_holder.get("error"):
        sys.exit(f"Authorization denied: {code_holder['error']}")
    code = code_holder.get("code")
    if not code:
        sys.exit("Timed out waiting for authorization redirect.")
    tok = _post_token(
        {"grant_type": "authorization_code", "code": code, "redirect_uri": REDIRECT_URI}
    )
    _save_token(tok)
    print("\n✓ Authorized. Refresh token stored at .secrets/spotify_token.json")


def _access_token():
    if not os.path.exists(TOKEN_PATH):
        sys.exit("Not authorized yet. Run: scripts/spotify.py auth")
    with open(TOKEN_PATH) as fh:
        tok = json.load(fh)
    refreshed = _post_token(
        {"grant_type": "refresh_token", "refresh_token": tok["refresh_token"]}
    )
    # Spotify may or may not return a new refresh_token; keep the old one if not.
    tok["access_token"] = refreshed["access_token"]
    if refreshed.get("refresh_token"):
        tok["refresh_token"] = refreshed["refresh_token"]
    _save_token(tok)
    return tok["access_token"]


def _get(path, token):
    req = urllib.request.Request(f"{API}{path}", headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


def _fmt(a):
    genres = ", ".join(a.get("genres", [])[:3])
    return f"{a['name']}  [pop {a.get('popularity','?')}]" + (f"  ({genres})" if genres else "")


def top(rng="medium", n=20):
    token = _access_token()
    rng = {"short": "short_term", "medium": "medium_term", "long": "long_term"}.get(rng, rng)
    data = _get(f"/me/top/artists?time_range={rng}&limit={min(int(n),50)}", token)
    for i, a in enumerate(data["items"], 1):
        print(f"{i:2}. {_fmt(a)}")


def recent(n=50):
    token = _access_token()
    data = _get(f"/me/player/recently-played?limit={min(int(n),50)}", token)
    seen, out = set(), []
    for item in data["items"]:
        for a in item["track"]["artists"]:
            if a["id"] not in seen:
                seen.add(a["id"])
                out.append(a["name"])
    for i, name in enumerate(out, 1):
        print(f"{i:2}. {name}")


def following():
    token = _access_token()
    data = _get("/me/following?type=artist&limit=50", token)
    for i, a in enumerate(data["artists"]["items"], 1):
        print(f"{i:2}. {_fmt(a)}")


def artists():
    """Union taste graph across top (3 ranges) + following, deduped by artist id."""
    token = _access_token()
    graph = {}
    for rng in ("short_term", "medium_term", "long_term"):
        for a in _get(f"/me/top/artists?time_range={rng}&limit=50", token)["items"]:
            graph.setdefault(a["id"], {"name": a["name"], "genres": a.get("genres", []), "sources": set()})["sources"].add(f"top_{rng}")
    for a in _get("/me/following?type=artist&limit=50", token)["artists"]["items"]:
        graph.setdefault(a["id"], {"name": a["name"], "genres": a.get("genres", []), "sources": set()})["sources"].add("following")
    print(f"{len(graph)} unique artists in taste graph:\n")
    for a in sorted(graph.values(), key=lambda x: x["name"].lower()):
        print(f"  {a['name']}  ({', '.join(sorted(a['sources']))})")


def names():
    """One artist name per line (machine-readable feed for the shows matcher)."""
    token = _access_token()
    seen = set()
    for rng in ("short_term", "medium_term", "long_term"):
        for a in _get(f"/me/top/artists?time_range={rng}&limit=50", token)["items"]:
            seen.add(a["name"])
    for a in _get("/me/following?type=artist&limit=50", token)["artists"]["items"]:
        seen.add(a["name"])
    for name in sorted(seen, key=str.lower):
        print(name)


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "top"
    args = sys.argv[2:]
    if cmd == "auth":
        authorize()
    elif cmd == "top":
        top(*args)
    elif cmd == "recent":
        recent(*args)
    elif cmd == "following":
        following()
    elif cmd == "artists":
        artists()
    elif cmd == "names":
        names()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
