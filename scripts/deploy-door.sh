#!/usr/bin/env bash
# deploy-door.sh — build, stage, probe, and promote the personal-door image.
#
# EVERY stage here is irreversible in the sense that matters: it changes a
# publicly-reachable service fronting the finance mirror. So nothing runs
# without an explicit stage argument, and `plan` (the default) only prints.
#
# Order:  plan → bootstrap (once) → secrets → build → candidate → probe → promote
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
  secrets     create the OAuth/JWT/Fernet secrets AND mint the 3 machine tokens
              (checkin-routine / checkin-watchdog / checkin-smoke). The door
              gets sha256 DIGESTS only; the raw tokens land in per-caller
              secrets. Re-running ROTATES the machine tokens.
  build       cloud build of door/Dockerfile -> \$IMAGE
  candidate   deploy \$IMAGE with NO traffic, tagged 'candidate'. Carries the
              PERSONAL_DOOR_GRANTS dial (identity -> tools + ET window).
  probe       POST /mcp on the candidate. Expect 401 with no auth AND a
              refusal for a bogus bearer. A 404 = wrong image.
  promote     shift 100% traffic to the candidate

After promote: a redeploy expires live MCP sessions, and a connector's tool list
is snapshotted when it is added. If the toolset changed, REMOVE and RE-ADD the
connector in claude.ai — a reconnect is not enough.
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

secrets)
  # Done as a stage rather than as copy-paste commands: a trailing newline on
  # the OAuth secret, or a Fernet key mangled by shell quoting, both fail late
  # and confusingly (at the Google token exchange, not at deploy).
  put() { # put NAME < value-on-stdin
    local name="$1"
    if gc secrets describe "$name" --project "$PROJECT" >/dev/null 2>&1; then
      gc secrets versions add "$name" --data-file=- --project "$PROJECT" >/dev/null
      echo "  $name — new version added"
    else
      gc secrets create "$name" --data-file=- --project "$PROJECT" >/dev/null
      echo "  $name — created"
    fi
  }

  printf 'Paste the OAuth client secret (input hidden), then Enter: '
  IFS= read -rs CLIENT_SECRET
  echo
  [ -n "$CLIENT_SECRET" ] || { echo "Empty. Nothing done." >&2; exit 1; }
  # printf %s, never echo: a trailing newline in the stored secret makes Google
  # reject the token exchange with an error that does not mention whitespace.
  printf %s "$CLIENT_SECRET" | put GOOGLE_OAUTH_CLIENT_SECRET
  unset CLIENT_SECRET

  openssl rand -base64 48 | tr -d '\n' | put JWT_SIGNING_KEY

  # A Fernet key is 32 random bytes in URL-SAFE base64. Plain `openssl -base64`
  # emits +/ which Fernet rejects, hence the tr.
  openssl rand 32 | base64 | tr '+/' '-_' | tr -d '\n' | put STORAGE_ENCRYPTION_KEY

  # --- machine identities (write side, U10) ---
  # One bearer token per non-interactive caller. The DOOR never sees these:
  # it is deployed with SHA-256 digests only, so a leaked door environment
  # cannot be replayed as a caller. The raw token secrets exist for the
  # callers (the cloud check-in routine, its watchdog, the deploy smoke),
  # which read PERSONAL_DOOR_MACHINE_TOKEN_<NAME>:latest at run time.
  #
  # Re-running this stage ROTATES all three tokens. Callers reading :latest
  # heal on their next run; anything pinned to an old version starts getting
  # 401s from the door — rotate deliberately, then watch the next check-in.
  DIGEST=""
  mint() { # mint SECRET_SUFFIX -> token secret stored; digest left in $DIGEST
    local name="$1" token
    token="$(openssl rand -hex 32)"   # 32 random bytes, hex — never echoed
    printf %s "$token" | put "PERSONAL_DOOR_MACHINE_TOKEN_${name}"
    DIGEST="$(printf %s "$token" | openssl dgst -sha256 | awk '{print $NF}')"
    unset -v token
  }
  mint CHECKIN_ROUTINE;  digest_routine="$DIGEST"
  mint CHECKIN_WATCHDOG; digest_watchdog="$DIGEST"
  mint CHECKIN_SMOKE;    digest_smoke="$DIGEST"
  printf '{"checkin-routine":"%s","checkin-watchdog":"%s","checkin-smoke":"%s"}' \
      "$digest_routine" "$digest_watchdog" "$digest_smoke" \
    | put PERSONAL_DOOR_MACHINE_TOKEN_DIGESTS

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
  echo "Machine tokens minted (raw values only in Secret Manager, never printed)."
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
  #   checkin-routine   check-in writes always; classification + its reads
  #                     only inside 06:45-23:00 America/New_York
  #   checkin-watchdog  may record a FAILED check-in and read the ledger;
  #                     classification never
  #   checkin-smoke     report reads only — safe for smokes and drills
  default_grants='{"checkin-routine":{"write_tools":["record_checkin","record_checkin_failed","reclassify_transaction","set_vendor_override","set_flow_override","add_vendor_mapping","add_vendor_alias","add_classification_rule","add_vendor_rule"],"read_tools":["run_finance_query","saved_query","list_saved_queries","feed_health"],"window":"06:45-23:00"},"checkin-watchdog":{"write_tools":["record_checkin_failed"],"read_tools":["run_finance_query"],"window":"always"},"checkin-smoke":{"write_tools":[],"read_tools":["run_finance_query","saved_query","feed_health"],"window":"always"}}'
  GRANTS="${PERSONAL_DOOR_GRANTS:-$default_grants}"

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
    --set-secrets "GOOGLE_OAUTH_CLIENT_SECRET=GOOGLE_OAUTH_CLIENT_SECRET:latest,JWT_SIGNING_KEY=JWT_SIGNING_KEY:latest,STORAGE_ENCRYPTION_KEY=STORAGE_ENCRYPTION_KEY:latest,PERSONAL_DOOR_MACHINE_TOKEN_DIGESTS=PERSONAL_DOOR_MACHINE_TOKEN_DIGESTS:latest"
  echo "Deployed. Next: $0 probe"
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
  ;;

promote)
  gc run services update-traffic "$SERVICE" --project "$PROJECT" --region "$REGION" --to-latest
  gc run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" \
    --format='value(status.url)'
  echo "Promoted. If the toolset changed, remove and re-add the connector in claude.ai."
  # Post-promote probes need REAL machine tokens, which this script deliberately
  # cannot read (they live in Secret Manager for the callers only) — so these
  # are operator steps, not automation:
  cat <<'EOF'

Post-promote checks of the grants dial (operator, with real caller tokens):
  1. In-window (06:45-23:00 America/New_York): a checkin-routine-token call to
     a classification tool (e.g. add_vendor_alias) should land, and its audit
     row should carry window_state='human'.
  2. Out-of-window: the same call should be REFUSED with a message naming the
     06:45-23:00 America/New_York window. record_checkin_failed should still
     land (window_state='autonomous').
  3. Smoke: the checkin-smoke token can run report reads (run_finance_query
     over finance.checkin_reports) and nothing else — every write refuses.
     Use ONLY checkin-smoke for smokes and drills; it cannot classify.
EOF
  ;;

*)
  echo "Unknown stage: $stage (plan|bootstrap|build|candidate|probe|promote)" >&2
  exit 2
  ;;
esac
