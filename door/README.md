# personal-door

A read-only MCP server that lets a Cowork seat (or any Claude session) query the
Tiller→BigQuery finance mirror. Google OAuth, one enrolled identity, no writes.

Design and rationale: `docs/personal-door-spec.md`. What is irreversible here:
`orchestration/PROFILE.md` §4.

## Shape

| File | Holds |
|---|---|
| `main.py` | tool declarations only — the docstrings are the interface |
| `auth.py` | Google OAuth wiring, `Identity`, encrypted persistent OAuth state |
| `service.py` | `DoorPolicy` / `_authorize` — the identity gate every tool passes |
| `finance_native.py` | the source whitelist, the SQL validator, the query runner |
| `saved_queries.py` | runs `queries/*.sql` by name; `feed_health` |

Authorization lives in `service.py`, not in the tools. A tool added later cannot
ship unprotected by forgetting a decorator — but it **must** be added as a
`DoorService` method that calls `_authorize` first. `door_whoami` is the single
deliberate exception: it answers for an unenrolled identity so a wrong-account
connection diagnoses itself, while still returning no data.

## Local smoke test

```bash
PERSONAL_DOOR_INSECURE_LOCAL=1 \
BASE_URL=http://localhost:8080 \
PERSONAL_DOOR_ALLOWED_EMAILS=you@example.com \
uv run --with-requirements door/requirements.txt python -m door.main
```

No-auth local mode starts the server, but its tools still reject anonymous
requests — verified: every governed tool returns `unauthorized` with no
identity. Tests inject identities directly into `DoorService`.

## Tests

```bash
uv run --with pytest --with google-cloud-bigquery python -m pytest tests/ -q
```

Offline: the SQL validator and the identity gate are pure logic, which is the
point — the two controls that matter most are provable on a laptop in a second.

## Deploying

```bash
./scripts/deploy-door.sh plan        # prints everything, changes nothing
./scripts/deploy-door.sh bootstrap   # once: AR repo, runtime SA, IAM, secrets
./scripts/deploy-door.sh build
./scripts/deploy-door.sh candidate   # no traffic, tagged 'candidate'
./scripts/deploy-door.sh probe       # 401 = healthy. 404 = wrong image. STOP.
./scripts/deploy-door.sh promote
```

Three lessons baked into that sequence, all learned the hard way on the Bobsled
door:

1. **Build with an explicit `-f door/Dockerfile`.** `gcloud builds submit --tag`
   auto-detects a repository-root Dockerfile; getting this wrong once shipped a
   revision that 404'd on every path including `/mcp`.
2. **Never let an unprobed image take traffic.** Deploy `--no-traffic`, probe,
   then shift. A healthy `/mcp` returns **401**, because auth is required.
3. **Exercise a real query after deploying, not just `door_whoami`.** The
   identity tools are file-based and pass happily while every data query 403s on
   a missing BigQuery grant.

After promoting: a redeploy expires live MCP sessions, and **a connector
snapshots its tool list when it is added**. If the toolset changed, remove and
re-add the connector in claude.ai — reconnecting is not enough.

## The perimeter, in one place

The Cloud Run URL is public, because claude.ai must reach it. Everything that
keeps it safe is here:

- **Google OAuth** with `openid`, `profile`, `userinfo.email`. Publish the
  consent screen to **Production** — apps left in Testing expire refresh tokens
  after 7 days. These scopes are non-sensitive, so no Google review is needed.
- **`PERSONAL_DOOR_ALLOWED_EMAILS`** — the only thing between a public URL and
  the finance mirror. The door refuses to start if it is empty. `email_verified`
  must be strictly `True`; Google's tokeninfo returns the *string* `"true"`, so
  a truthiness check here would also accept `"false"`.
- **Read-only SQL** over a 36-source whitelist, single statement, dry-run first,
  1 GiB billed and 500 rows capped. `tiller_raw` is unreachable by design.
- **Runtime SA** holds BigQuery viewer/jobUser and Firestore user. No Drive
  scope, no write roles, no key file.
- **Encrypted persistent OAuth state** in Firestore (Fernet-wrapped). Without it
  the door refuses to start on a non-loopback URL, because OAuth registrations on
  ephemeral disk are lost on every cold start and silently break the connector.
