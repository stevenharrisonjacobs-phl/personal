#!/usr/bin/env bash
# deploy-door.sh — build, stage, probe, and promote the personal-door image.
#
# EVERY stage here is irreversible in the sense that matters: it changes a
# publicly-reachable service fronting the finance mirror. So nothing runs
# without an explicit stage argument, and `plan` (the default) only prints.
#
# Order:  plan → bootstrap (once) → secrets → build → candidate → probe → promote
#
# Every stage that creates state is CREATE-IF-ABSENT. Rotation is never a
# side effect of re-running setup: it has its own stages, because the OAuth
# secrets and the machine tokens have completely different blast radii.
#
# The candidate-then-probe dance is not ceremony. A broken image must never take
# requests, and the tell is specific: on a healthy revision /mcp returns 401
# (auth required). A 404 means the wrong image shipped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="${DOOR_PROJECT:-steven-tiller-finance-2026}"
REGION="${DOOR_REGION:-us-central1}"
SERVICE="${DOOR_SERVICE:-personal-door}"
REPO="${DOOR_AR_REPO:-door}"
ACCOUNT="${DOOR_GCLOUD_ACCOUNT:-steven@plumgrowth.ai}"
TAG="$(git rev-parse --short HEAD 2>/dev/null || echo manual)"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/${SERVICE}:${TAG}"
SA="${SERVICE}-runtime@${PROJECT}.iam.gserviceaccount.com"

gc() { CLOUDSDK_CORE_ACCOUNT="$ACCOUNT" gcloud "$@"; }

stage="${1:-plan}"

case "$stage" in

plan)
  cat <<EOF
personal-door deploy plan

  project   $PROJECT
  region    $REGION
  service   $SERVICE
  image     $IMAGE
  runtime SA $SA
  gcloud as $ACCOUNT

Stages (run one at a time, read the output of each):

  bootstrap   one-time: Artifact Registry repo, runtime SA, BigQuery + Firestore IAM
  secrets     CREATE-IF-ABSENT: the OAuth/JWT/Fernet secrets and the 3 machine
              tokens (checkin-routine / checkin-watchdog / checkin-smoke). The
              door gets sha256 DIGESTS only; the raw tokens land in per-caller
              secrets. Re-running this stage changes NOTHING that already
              exists — see the rotate-* stages.
  rotate-tokens        mint new machine tokens (and a new digests version).
              Requires the redeploy sequence printed at the end; until then the
              live revision still holds the OLD digests.
  rotate-oauth-secret  add a new version of the Google OAuth client secret.
  build       cloud build of door/Dockerfile -> \$IMAGE
  candidate   deploy \$IMAGE with NO traffic, tagged 'candidate'. Carries the
              PERSONAL_DOOR_GRANTS dial (identity -> tools + ET window) and
              PINS every secret to the version current at deploy time.
  probe       POST /mcp on the candidate. Expect 401 with no auth AND a
              refusal for a bogus bearer. A 404 = wrong image. Then verifies
              the grants dial with the REAL machine tokens (read back from
              Secret Manager): every token authenticates, and out-of-grant
              calls are refused. Any mismatch fails the deploy.
  promote     shift 100% traffic to the candidate

After promote: a redeploy expires live MCP sessions, and a connector's tool list
is snapshotted when it is added. If the toolset changed, REMOVE and RE-ADD the
connector in claude.ai — a reconnect is not enough.

Secret versions are PINNED per revision, never ':latest'. Cloud Run resolves
secret env vars when an INSTANCE starts, not once per deploy, so ':latest' lets
a warm instance and a cold one disagree about which digests are valid — a
rotation would then produce intermittent, unattributable 401s. Pinning makes a
revision's configuration immutable: adding a secret version changes nothing
until you deploy a new candidate and promote it.
EOF
  ;;

bootstrap)
  echo "One-time setup in $PROJECT. Ctrl-C now if that is not what you want."
  read -r -p "Type the project id to continue: " confirm
  [ "$confirm" = "$PROJECT" ] || { echo "Mismatch. Nothing done." >&2; exit 1; }

  gc services enable run.googleapis.com cloudbuild.googleapis.com \
    artifactregistry.googleapis.com firestore.googleapis.com \
    secretmanager.googleapis.com --project "$PROJECT"

  gc artifacts repositories describe "$REPO" --location "$REGION" --project "$PROJECT" >/dev/null 2>&1 \
    || gc artifacts repositories create "$REPO" --repository-format=docker \
         --location "$REGION" --project "$PROJECT" \
         --description "personal-door images"

  gc iam service-accounts describe "$SA" --project "$PROJECT" >/dev/null 2>&1 \
    || gc iam service-accounts create "${SERVICE}-runtime" --project "$PROJECT" \
         --display-name "personal-door runtime"

  # A freshly created service account is not immediately visible to the IAM
  # policy API, so binding a role right after creating it fails with a flatly
  # untrue "does not exist". Wait for it to actually resolve.
  echo -n "Waiting for the service account to propagate to IAM"
  for _ in $(seq 1 30); do
    if gc iam service-accounts describe "$SA" --project "$PROJECT" >/dev/null 2>&1; then
      # describe succeeding is necessary but not sufficient — the policy API
      # lags behind it, so probe with the real operation.
      if gc projects add-iam-policy-binding "$PROJECT" \
           --member "serviceAccount:$SA" --role roles/bigquery.jobUser \
           --condition=None >/dev/null 2>&1; then
        echo " ok"
        break
      fi
    fi
    echo -n "."
    sleep 4
  done

  # Read-only on the warehouse; Firestore for encrypted OAuth state. No Drive
  # scope anywhere — that is what keeps tiller_raw genuinely unreachable.
  # Idempotent: re-adding an existing binding is a no-op, so re-running is safe.
  for role in roles/bigquery.dataViewer roles/bigquery.jobUser roles/datastore.user; do
    gc projects add-iam-policy-binding "$PROJECT" \
      --member "serviceAccount:$SA" --role "$role" --condition=None >/dev/null \
      || { echo "FAILED to grant $role — re-run bootstrap." >&2; exit 1; }
    echo "  granted $role"
  done

  # Cloud Build runs as the COMPUTE default service account, not the legacy
  # @cloudbuild.gserviceaccount.com one, and on a project that has never built
  # anything it holds no roles at all. The failure is a 403 on the staging
  # BUCKET ("does not have storage.objects.get"), which reads like a Cloud
  # Storage problem rather than a missing build identity. builds.builder bundles
  # the three it needs: staging-bucket access, Artifact Registry write, and log
  # write (required because cloudbuild.yaml sets CLOUD_LOGGING_ONLY).
  project_number=$(gc projects describe "$PROJECT" --format='value(projectNumber)')
  build_sa="${project_number}-compute@developer.gserviceaccount.com"
  gc projects add-iam-policy-binding "$PROJECT" \
    --member "serviceAccount:$build_sa" --role roles/cloudbuild.builds.builder \
    --condition=None >/dev/null \
    || { echo "FAILED to grant the build SA — re-run bootstrap." >&2; exit 1; }
  echo "  granted roles/cloudbuild.builds.builder to $build_sa"

  echo
  echo "Bootstrap done. Next: $0 secrets"
  ;;

secrets|rotate-tokens|rotate-oauth-secret)
  # Done as a stage rather than as copy-paste commands: a trailing newline on
  # the OAuth secret, or a Fernet key mangled by shell quoting, both fail late
  # and confusingly (at the Google token exchange, not at deploy).
  #
  # CREATE-IF-ABSENT is the whole point of the split. `secrets` used to add a
  # new version of everything on every run, which made "rotate the machine
  # tokens" also mean "throw away the JWT signing key and the Fernet key" —
  # invalidating every issued JWT and rendering every Firestore record
  # encrypted under the old Fernet key permanently unreadable. Those two keys
  # now have no rotation stage at all, deliberately: rotating
  # STORAGE_ENCRYPTION_KEY without a re-encrypt migration is data loss, not
  # rotation.
  have() { gc secrets describe "$1" --project "$PROJECT" >/dev/null 2>&1; }

  add_version() { # add_version NAME < value-on-stdin  — always a new version
    local name="$1"
    if have "$name"; then
      gc secrets versions add "$name" --data-file=- --project "$PROJECT" >/dev/null
      echo "  $name — new version added"
    else
      gc secrets create "$name" --data-file=- --project "$PROJECT" >/dev/null
      echo "  $name — created"
    fi
  }

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

  # --- machine identities (write side, U10) ---
  # One bearer token per non-interactive caller. The DOOR never sees these:
  # it is deployed with SHA-256 digests only, so a leaked door environment
  # cannot be replayed as a caller. The raw token secrets exist for the
  # callers (the cloud check-in routine, its watchdog, the deploy smoke),
  # which read PERSONAL_DOOR_MACHINE_TOKEN_<NAME>:latest at run time.
  DIGEST=""
  mint() { # mint SECRET_SUFFIX WRITER -> token stored; digest left in $DIGEST
    local name="$1" writer="$2" token
    token="$(openssl rand -hex 32)"   # 32 random bytes, hex — never echoed
    printf %s "$token" | "$writer" "PERSONAL_DOOR_MACHINE_TOKEN_${name}"
    DIGEST="$(printf %s "$token" | openssl dgst -sha256 | awk '{print $NF}')"
    unset -v token
  }
  mint_all() { # mint_all WRITER — the three identities plus the digests map
    local writer="$1" digest_routine digest_watchdog digest_smoke
    mint CHECKIN_ROUTINE  "$writer"; digest_routine="$DIGEST"
    mint CHECKIN_WATCHDOG "$writer"; digest_watchdog="$DIGEST"
    mint CHECKIN_SMOKE    "$writer"; digest_smoke="$DIGEST"
    printf '{"checkin-routine":"%s","checkin-watchdog":"%s","checkin-smoke":"%s"}' \
        "$digest_routine" "$digest_watchdog" "$digest_smoke" \
      | "$writer" PERSONAL_DOOR_MACHINE_TOKEN_DIGESTS
  }

  case "$stage" in

  rotate-oauth-secret)
    printf 'Paste the NEW OAuth client secret (input hidden), then Enter: '
    IFS= read -rs CLIENT_SECRET
    echo
    [ -n "$CLIENT_SECRET" ] || { echo "Empty. Nothing done." >&2; exit 1; }
    printf %s "$CLIENT_SECRET" | add_version GOOGLE_OAUTH_CLIENT_SECRET
    unset CLIENT_SECRET
    echo
    echo "A new version exists, but revisions PIN secret versions — the live"
    echo "door still uses the old one. To cut over: $0 build && $0 candidate"
    echo "&& $0 probe && $0 promote"
    exit 0
    ;;

  rotate-tokens)
    have PERSONAL_DOOR_MACHINE_TOKEN_DIGESTS \
      || { echo "No machine tokens exist yet. Run: $0 secrets" >&2; exit 1; }
    echo "Rotating all three machine tokens in $PROJECT."
    echo
    echo "The new tokens are live in Secret Manager IMMEDIATELY, but the door"
    echo "will not accept them until a revision pinned to the new digests is"
    echo "promoted. Any caller reading :latest in between gets a 401. Do this"
    echo "when a missed check-in is acceptable, and run the redeploy now."
    read -r -p "Type the project id to continue: " confirm
    [ "$confirm" = "$PROJECT" ] || { echo "Mismatch. Nothing done." >&2; exit 1; }
    mint_all add_version
    echo
    echo "Rotated. The cutover is NOT complete until you run, in order:"
    echo "  $0 build && $0 candidate && $0 probe && $0 promote"
    echo "The candidate stage pins the new digest version; probe verifies the"
    echo "new tokens against it BEFORE any traffic moves."
    exit 0
    ;;

  esac

  # --- stage: secrets (create-if-absent) ---
  if have GOOGLE_OAUTH_CLIENT_SECRET; then
    echo "  GOOGLE_OAUTH_CLIENT_SECRET — exists, left alone"
  else
    printf 'Paste the OAuth client secret (input hidden), then Enter: '
    IFS= read -rs CLIENT_SECRET
    echo
    [ -n "$CLIENT_SECRET" ] || { echo "Empty. Nothing done." >&2; exit 1; }
    # printf %s, never echo: a trailing newline in the stored secret makes
    # Google reject the token exchange with an error that never mentions
    # whitespace.
    printf %s "$CLIENT_SECRET" | put_if_absent GOOGLE_OAUTH_CLIENT_SECRET
    unset CLIENT_SECRET
  fi

  openssl rand -base64 48 | tr -d '\n' | put_if_absent JWT_SIGNING_KEY

  # A Fernet key is 32 random bytes in URL-SAFE base64. Plain `openssl -base64`
  # emits +/ which Fernet rejects, hence the tr.
  openssl rand 32 | base64 | tr '+/' '-_' | tr -d '\n' | put_if_absent STORAGE_ENCRYPTION_KEY

  if have PERSONAL_DOOR_MACHINE_TOKEN_DIGESTS; then
    echo "  machine tokens — exist, left alone (rotate with: $0 rotate-tokens)"
  else
    mint_all put_if_absent
  fi

  # The runtime SA may read the digests but NOT the raw tokens — the door
  # verifies, it never impersonates. Grant each CALLER's service account
  # accessor on ITS token secret only, when wiring the scheduler:
  #   gcloud secrets add-iam-policy-binding PERSONAL_DOOR_MACHINE_TOKEN_CHECKIN_ROUTINE \
  #     --member serviceAccount:<caller-sa> --role roles/secretmanager.secretAccessor
  for s in GOOGLE_OAUTH_CLIENT_SECRET JWT_SIGNING_KEY STORAGE_ENCRYPTION_KEY \
           PERSONAL_DOOR_MACHINE_TOKEN_DIGESTS; do
    gc secrets add-iam-policy-binding "$s" \
      --member "serviceAccount:$SA" \
      --role roles/secretmanager.secretAccessor \
      --project "$PROJECT" >/dev/null
  done
  echo "Runtime SA granted: OAuth/JWT/Fernet secrets + the token DIGESTS."
  echo "Anything already present was left untouched — re-running is safe."
  echo "Next: $0 build"
  ;;

build)
  gc builds submit --project "$PROJECT" --region "$REGION" \
    --config door/cloudbuild.yaml --substitutions "_IMAGE=$IMAGE" .
  echo "Built $IMAGE"
  ;;

candidate)
  # IMAGE is tagged with the current HEAD sha, so committing between `build` and
  # `candidate` silently retargets this at an image that was never built. Cloud
  # Run's own error for that is a generic manifest-not-found, so check here and
  # say the actual remedy.
  if ! gc artifacts docker images describe "$IMAGE" --project "$PROJECT" >/dev/null 2>&1; then
    echo "No image at $IMAGE" >&2
    echo "HEAD moved since the last build. Run: $0 build" >&2
    exit 1
  fi

  : "${PERSONAL_DOOR_ALLOWED_EMAILS:?set PERSONAL_DOOR_ALLOWED_EMAILS}"
  : "${BASE_URL:?set BASE_URL to the service origin}"
  : "${GOOGLE_OAUTH_CLIENT_ID:?set GOOGLE_OAUTH_CLIENT_ID}"
  case "$GOOGLE_OAUTH_CLIENT_ID" in
    PASTE_*|*replace-with-*|"")
      echo "GOOGLE_OAUTH_CLIENT_ID is still the placeholder — paste the real one." >&2
      exit 1 ;;
  esac

  # --no-traffic is rejected when CREATING a service, so the first deploy cannot
  # use the candidate pattern. That is fine: a service with no prior revision has
  # no live traffic to shield, and it is still gated by OAuth + the allowlist
  # with nothing connected to it yet. Every later deploy gets the full dance.
  traffic_args=(--no-traffic --tag candidate)
  if ! gc run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" >/dev/null 2>&1; then
    echo "First deploy — creating the service, so this revision takes traffic"
    echo "immediately (Cloud Run rejects --no-traffic on creation). Nothing is"
    echo "connected to it yet, and OAuth + the allowlist still gate every call."
    traffic_args=()
  fi

  # The schedule dial. Server-side and per identity (KD5): what each machine
  # identity may call, and — for classification tools — WHEN, inclusive ET
  # window. Machine identities absent from this map are refused everything.
  # Override by exporting PERSONAL_DOOR_GRANTS before this stage; the default
  # is the canonical dial:
  #   checkin-routine   check-in writes and granted reads always;
  #                     classification writes only inside 06:45-23:00
  #                     America/New_York
  #   checkin-watchdog  may record a FAILED check-in; reads ONLY saved_query +
  #                     list_saved_queries. Its existence check runs the
  #                     latest-spend-checkin saved query (the newest success
  #                     row) and compares that row's run_ts date in ET — it
  #                     never needs free-form SELECT over the mirror.
  #   checkin-smoke     saved-query reads + feed_health only — safe for
  #                     smokes and drills; no free-form SQL, no writes
  # run_finance_query (arbitrary read-only SELECT over the whole finance
  # mirror) is granted to checkin-routine ONLY — least privilege for the
  # watchdog and smoke is the enumerated saved-query surface, not SELECT *.
  default_grants='{"checkin-routine":{"write_tools":["record_checkin","record_checkin_failed","reclassify_transaction","set_vendor_override","set_flow_override","add_vendor_mapping","add_vendor_alias","add_classification_rule","add_vendor_rule"],"read_tools":["run_finance_query","saved_query","list_saved_queries","feed_health"],"window":"06:45-23:00"},"checkin-watchdog":{"write_tools":["record_checkin_failed"],"read_tools":["saved_query","list_saved_queries"],"window":"always"},"checkin-smoke":{"write_tools":[],"read_tools":["saved_query","list_saved_queries","feed_health"],"window":"always"}}'
  GRANTS="${PERSONAL_DOOR_GRANTS:-$default_grants}"

  # Pin every secret to the version that is current RIGHT NOW, never :latest.
  # Cloud Run resolves secret env vars when an INSTANCE starts, not once per
  # deploy: with :latest, adding a secret version leaves warm instances on the
  # old value while newly started ones get the new one. For the token digests
  # that is split-brain authentication — the same caller token is accepted or
  # 401'd depending on which instance answers, intermittently and with nothing
  # in the logs naming rotation as the cause. Pinning makes a revision's
  # configuration immutable, so rotation is a deploy, which is observable.
  # Appends to $secret_args rather than printing, so a failure to resolve any
  # ONE version aborts here. Composing with $(pin a),$(pin b) would not: the
  # exit status of that assignment is only the LAST substitution's, so a
  # silently empty first element would ship a malformed --set-secrets.
  secret_args=""
  pin() { # pin NAME -> appends NAME=NAME:<n> to $secret_args
    local name="$1" version
    # `|| true` because set -e would otherwise kill the stage before the case
    # below can say WHICH secret is missing and what to run about it.
    version=$(gc secrets versions describe latest --secret "$name" \
                --project "$PROJECT" --format='value(name)' 2>/dev/null \
              | sed 's#.*/##' || true)
    case "$version" in
      ''|*[!0-9]*)
        echo "Could not resolve a version for secret $name." >&2
        echo "Run: $0 secrets" >&2
        exit 1 ;;
    esac
    echo "  $name -> version $version"
    secret_args="${secret_args:+$secret_args,}${name}=${name}:${version}"
  }
  echo "Pinning secret versions for this revision:"
  pin GOOGLE_OAUTH_CLIENT_SECRET
  pin JWT_SIGNING_KEY
  pin STORAGE_ENCRYPTION_KEY
  pin PERSONAL_DOOR_MACHINE_TOKEN_DIGESTS

  # --no-invoker-iam-check keeps the URL publicly reachable (claude.ai must
  # reach it) while the door's own OAuth + allowlist remain the perimeter.
  #
  # ^##^ switches gcloud's --set-env-vars delimiter from comma to ##: the
  # grants JSON is full of commas, and the default splitting would shred it
  # into nonsense env vars that fail only at container startup. (## and not @,
  # because the allowlist value is an email address.)
  gc run deploy "$SERVICE" --project "$PROJECT" --region "$REGION" \
    --image "$IMAGE" \
    --service-account "$SA" \
    --no-invoker-iam-check \
    "${traffic_args[@]}" \
    --set-env-vars "^##^GCP_PROJECT_ID=${PROJECT}##FINANCE_DATASET=finance##GOLD_DATASET=gold##FIRESTORE_PROJECT=${PROJECT}##PERSONAL_DOOR_ALLOWED_EMAILS=${PERSONAL_DOOR_ALLOWED_EMAILS}##BASE_URL=${BASE_URL}##GOOGLE_OAUTH_CLIENT_ID=${GOOGLE_OAUTH_CLIENT_ID}##PERSONAL_DOOR_GRANTS=${GRANTS}" \
    --set-secrets "$secret_args"
  echo "Deployed with pinned secret versions. Next: $0 probe"
  ;;

probe)
  # Prefer the candidate tag; on a first deploy there is no candidate, so fall
  # back to the service's own URL rather than reporting a missing deploy.
  # `|| true` is load-bearing: with no candidate tag, grep exits 1, and under
  # `set -e` with pipefail that aborts the whole script inside the command
  # substitution — before the fallback below can run. The symptom is a probe
  # that prints nothing and exits 1, which looks exactly like a dead service.
  url=$(gc run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" \
        --format='value(status.traffic.url)' 2>/dev/null | tr ' ' '\n' | grep candidate | head -1 || true)
  if [ -z "$url" ]; then
    url=$(gc run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" \
          --format='value(status.url)' 2>/dev/null)
    [ -n "$url" ] && echo "(no candidate tag — probing the live service URL)"
  fi
  [ -n "$url" ] || { echo "Service not found. Deploy first: $0 candidate" >&2; exit 1; }
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url/mcp" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
  echo "$url/mcp (no auth) -> HTTP $code"
  case "$code" in
    401) echo "HEALTHY — auth is required, which is the correct answer." ;;
    404) echo "WRONG IMAGE — /mcp is not served. Do NOT promote." >&2; exit 1 ;;
    *)   echo "UNEXPECTED — investigate before promoting." >&2; exit 1 ;;
  esac

  # Second probe: a made-up bearer token. This is the machine-token path
  # failing closed — the composite verifier must refuse a token whose digest
  # is not enrolled. 401 and 403 both count as refusal; anything else means
  # garbage was accepted at the transport, and promoting would put that in
  # front of the finance mirror.
  bogus="bogus-$(openssl rand -hex 16)"
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url/mcp" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer ${bogus}" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
  echo "$url/mcp (bogus bearer) -> HTTP $code"
  case "$code" in
    401|403) echo "HEALTHY — an unenrolled bearer token is refused." ;;
    *)  echo "UNEXPECTED — a bogus bearer was NOT refused. Do NOT promote." >&2
        exit 1 ;;
  esac

  # Third probe: the grants dial itself, with the REAL machine tokens. The
  # transport probes above cannot catch a candidate whose VALID-token auth is
  # broken, or whose grants map was mis-parsed into over- or under-granting —
  # both promote silently without this. The operator identity running this
  # script created the token secrets in the `secrets` stage, so it reads them
  # back the same way (the DOOR still never sees a raw token — only digests).
  #
  # Four assertions, all against the candidate URL:
  #   a. every token AUTHENTICATES — a cheap granted read succeeds
  #   b. checkin-watchdog calling a classification tool -> forbidden
  #   c. checkin-smoke calling a classification tool    -> forbidden
  #   d. checkin-watchdog calling run_finance_query     -> forbidden
  #      (a governed read, deliberately NOT in its grant)
  #
  # If assertion (a) fails, first suspect `rotate-tokens` run AFTER this
  # candidate deployed: the candidate PINS the digests version it saw, while
  # read_token below reads :latest, so the probe would be presenting new
  # tokens to a revision that only knows the old digests. That is the pin
  # working as intended — it fails here, loudly, instead of intermittently in
  # production. Re-run: candidate, then probe.
  echo
  echo "Verifying the grants dial against the candidate (real machine tokens)..."

  read_token() { # read_token NAME -> raw token on stdout
    gc secrets versions access latest \
      --secret "PERSONAL_DOOR_MACHINE_TOKEN_${1}" --project "$PROJECT"
  }

  mcp_call() { # mcp_call TOKEN TOOL ARGS_JSON -> prints the tools/call response
    local token="$1" tool="$2" args="$3" hdrs body sid
    hdrs="$(mktemp)"
    body=$(curl -s -D "$hdrs" -X POST "$url/mcp" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -H "Authorization: Bearer ${token}" \
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"deploy-door-probe","version":"0"}}}')
    sid=$(awk 'tolower($1)=="mcp-session-id:" {print $2}' "$hdrs" | tr -d '\r')
    rm -f "$hdrs"
    if [ -z "$sid" ]; then
      # No session means the token did not authenticate — surface the body so
      # the failure explains itself instead of looking like a dead service.
      printf 'NO_SESSION %s' "$body"
      return 0
    fi
    curl -s -o /dev/null -X POST "$url/mcp" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -H "Authorization: Bearer ${token}" -H "Mcp-Session-Id: ${sid}" \
      -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    curl -s -X POST "$url/mcp" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -H "Authorization: Bearer ${token}" -H "Mcp-Session-Id: ${sid}" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"${tool}\",\"arguments\":${args}}}"
  }

  # The door's refusals are IN-BAND tool results: {"status":"forbidden",...}.
  # They appear unescaped in structuredContent and \"-escaped in the text
  # content block, so the pattern tolerates both.
  forbidden_pat='\\?"status\\?"[[:space:]]*:[[:space:]]*\\?"forbidden\\?"'
  grants_fail=0
  expect_ok() { # expect_ok LABEL RESPONSE — a granted read must succeed
    local label="$1" resp="$2"
    if printf %s "$resp" | grep -q '^NO_SESSION'; then
      echo "FAILED  $label — token did NOT authenticate: $(printf %s "$resp" | head -c 300)" >&2
      grants_fail=1
    elif printf %s "$resp" | grep -Eq "$forbidden_pat"; then
      echo "FAILED  $label — granted call was refused: $(printf %s "$resp" | head -c 300)" >&2
      grants_fail=1
    elif ! printf %s "$resp" | grep -q '"result"'; then
      echo "FAILED  $label — no result: $(printf %s "$resp" | head -c 300)" >&2
      grants_fail=1
    else
      echo "ok      $label"
    fi
  }
  expect_forbidden() { # expect_forbidden LABEL RESPONSE — the dial must refuse
    local label="$1" resp="$2"
    if printf %s "$resp" | grep -Eq "$forbidden_pat"; then
      echo "ok      $label"
    else
      echo "FAILED  $label — expected forbidden, got: $(printf %s "$resp" | head -c 300)" >&2
      grants_fail=1
    fi
  }

  tok_routine="$(read_token CHECKIN_ROUTINE)"
  tok_watchdog="$(read_token CHECKIN_WATCHDOG)"
  tok_smoke="$(read_token CHECKIN_SMOKE)"

  # (a) every token authenticates: list_saved_queries is granted to all three
  # identities and reads only the in-repo catalog — no warehouse bytes.
  expect_ok "routine  auth + granted read (list_saved_queries)" \
    "$(mcp_call "$tok_routine" list_saved_queries '{}')"
  expect_ok "watchdog auth + granted read (list_saved_queries)" \
    "$(mcp_call "$tok_watchdog" list_saved_queries '{}')"
  expect_ok "smoke    auth + granted read (list_saved_queries)" \
    "$(mcp_call "$tok_smoke" list_saved_queries '{}')"

  # (b)+(c) classification must refuse for watchdog and smoke. The refusal
  # happens in the service's authorize gate BEFORE any write runtime runs; the
  # probe-marked arguments only exist so argument validation lets the call
  # reach that gate. If one of these WRONGLY lands, the deploy fails and the
  # stray gold.vendor_aliases row below is the cleanup target.
  probe_args='{"alias_name":"deploy-door-grants-probe","canonical_vendor_name":"deploy-door-grants-probe","notes":"must never land — deploy probe"}'
  expect_forbidden "watchdog classification refused (add_vendor_alias)" \
    "$(mcp_call "$tok_watchdog" add_vendor_alias "$probe_args")"
  expect_forbidden "smoke    classification refused (add_vendor_alias)" \
    "$(mcp_call "$tok_smoke" add_vendor_alias "$probe_args")"

  # (d) granted-but-out-of-scope: run_finance_query is a real governed read,
  # deliberately absent from the watchdog's grant. dry_run keeps it free even
  # in the failure case where it wrongly executes.
  expect_forbidden "watchdog run_finance_query refused (not in grant)" \
    "$(mcp_call "$tok_watchdog" run_finance_query '{"sql":"SELECT 1","dry_run":true}')"

  unset -v tok_routine tok_watchdog tok_smoke

  if [ "$grants_fail" -ne 0 ]; then
    echo "GRANTS DIAL BROKEN on the candidate — do NOT promote." >&2
    exit 1
  fi
  echo "HEALTHY — the grants dial verified against the candidate."
  ;;

promote)
  gc run services update-traffic "$SERVICE" --project "$PROJECT" --region "$REGION" --to-latest
  gc run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" \
    --format='value(status.url)'
  echo "Promoted. If the toolset changed, remove and re-add the connector in claude.ai."
  # The probe stage already verified the grants dial mechanically (every token
  # authenticates; watchdog/smoke classification and watchdog run_finance_query
  # all refuse). What remains is operator work because it depends on the wall
  # clock and on landing REAL writes:
  cat <<'EOF'

Post-promote checks of the window dial (operator, with real caller tokens):
  1. In-window (06:45-23:00 America/New_York): a checkin-routine-token call to
     a classification tool (e.g. add_vendor_alias) should land, and its audit
     row should carry window_state='human'.
  2. Out-of-window: the same call should be REFUSED with a message naming the
     06:45-23:00 America/New_York window. record_checkin_failed should still
     land (window_state='autonomous').
  3. Smoke: use ONLY checkin-smoke for smokes and drills — its grant is
     saved_query / list_saved_queries / feed_health and nothing else. No
     free-form SQL, no writes, no classification.
EOF
  ;;

*)
  echo "Unknown stage: $stage" >&2
  echo "  setup:  plan | bootstrap | secrets" >&2
  echo "  deploy: build | candidate | probe | promote" >&2
  echo "  rotate: rotate-tokens | rotate-oauth-secret" >&2
  exit 2
  ;;
esac
