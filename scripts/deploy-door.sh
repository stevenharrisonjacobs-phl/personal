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
  secrets     create the 3 secrets (prompts for the OAuth secret, generates the rest)
  build       cloud build of door/Dockerfile -> \$IMAGE
  candidate   deploy \$IMAGE with NO traffic, tagged 'candidate'
  probe       POST /mcp on the candidate. Expect 401. A 404 = wrong image.
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

  # Read-only on the warehouse; Firestore for encrypted OAuth state. No Drive
  # scope anywhere — that is what keeps tiller_raw genuinely unreachable.
  gc projects add-iam-policy-binding "$PROJECT" \
    --member "serviceAccount:$SA" --role roles/bigquery.dataViewer --condition=None >/dev/null
  gc projects add-iam-policy-binding "$PROJECT" \
    --member "serviceAccount:$SA" --role roles/bigquery.jobUser --condition=None >/dev/null
  gc projects add-iam-policy-binding "$PROJECT" \
    --member "serviceAccount:$SA" --role roles/datastore.user --condition=None >/dev/null

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

  for s in GOOGLE_OAUTH_CLIENT_SECRET JWT_SIGNING_KEY STORAGE_ENCRYPTION_KEY; do
    gc secrets add-iam-policy-binding "$s" \
      --member "serviceAccount:$SA" \
      --role roles/secretmanager.secretAccessor \
      --project "$PROJECT" >/dev/null
  done
  echo "Runtime SA granted access to all three."
  echo "Next: $0 build"
  ;;

build)
  gc builds submit --project "$PROJECT" --region "$REGION" \
    --config door/cloudbuild.yaml --substitutions "_IMAGE=$IMAGE" .
  echo "Built $IMAGE"
  ;;

candidate)
  # --no-invoker-iam-check keeps the URL publicly reachable (claude.ai must
  # reach it) while the door's own OAuth + allowlist remain the perimeter.
  gc run deploy "$SERVICE" --project "$PROJECT" --region "$REGION" \
    --image "$IMAGE" \
    --service-account "$SA" \
    --no-invoker-iam-check \
    --no-traffic --tag candidate \
    --set-env-vars "GCP_PROJECT_ID=${PROJECT},FINANCE_DATASET=finance,GOLD_DATASET=gold,FIRESTORE_PROJECT=${PROJECT},PERSONAL_DOOR_ALLOWED_EMAILS=${PERSONAL_DOOR_ALLOWED_EMAILS:?set PERSONAL_DOOR_ALLOWED_EMAILS},BASE_URL=${BASE_URL:?set BASE_URL to the service origin},GOOGLE_OAUTH_CLIENT_ID=${GOOGLE_OAUTH_CLIENT_ID:?set GOOGLE_OAUTH_CLIENT_ID}" \
    --set-secrets "GOOGLE_OAUTH_CLIENT_SECRET=GOOGLE_OAUTH_CLIENT_SECRET:latest,JWT_SIGNING_KEY=JWT_SIGNING_KEY:latest,STORAGE_ENCRYPTION_KEY=STORAGE_ENCRYPTION_KEY:latest"
  echo "Candidate deployed with no traffic. Next: $0 probe"
  ;;

probe)
  url=$(gc run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" \
        --format='value(status.traffic.url)' | tr ' ' '\n' | grep candidate | head -1)
  [ -n "$url" ] || { echo "No candidate URL found. Deploy a candidate first." >&2; exit 1; }
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url/mcp" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
  echo "$url/mcp -> HTTP $code"
  case "$code" in
    401) echo "HEALTHY — auth is required, which is the correct answer." ;;
    404) echo "WRONG IMAGE — /mcp is not served. Do NOT promote." >&2; exit 1 ;;
    *)   echo "UNEXPECTED — investigate before promoting." >&2; exit 1 ;;
  esac
  ;;

promote)
  gc run services update-traffic "$SERVICE" --project "$PROJECT" --region "$REGION" --to-latest
  gc run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" \
    --format='value(status.url)'
  echo "Promoted. If the toolset changed, remove and re-add the connector in claude.ai."
  ;;

*)
  echo "Unknown stage: $stage (plan|bootstrap|build|candidate|probe|promote)" >&2
  exit 2
  ;;
esac
