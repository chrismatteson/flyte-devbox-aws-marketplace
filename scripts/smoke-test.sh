#!/usr/bin/env bash
# Integration smoke test: deploy a throwaway Prod stack, authenticate via the
# Cognito M2M client (no browser), run a workflow, assert it was created, then
# tear everything down. Spends real AWS money — run manually / from the Buildkite
# "aws" queue. Idempotent teardown via EXIT trap.
#
# Required env (have sane defaults for the union-presales account):
#   DOMAIN          fully-qualified name for the test stack (its Route 53 zone is
#                   auto-discovered by the template — no zone id needed)
# Optional:
#   STACK_NAME (default flyte-devbox-smoke)  REGION (us-east-1)
#   AWS_PROFILE (unset => ambient creds)     AMI_ID (override template default)
set -euo pipefail

STACK_NAME="${STACK_NAME:-flyte-devbox-smoke}"
REGION="${REGION:-us-east-1}"
DOMAIN="${DOMAIN:-smoke.flytedemo.app}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/cloudformation/flyte-devbox.yaml"
AWSP=(); [ -n "${AWS_PROFILE:-}" ] && AWSP=(--profile "$AWS_PROFILE")
aws_() { aws "${AWSP[@]}" --region "$REGION" "$@"; }

log() { printf '\n\033[36m▶ %s\033[0m\n' "$*"; }

teardown() {
  log "Teardown: deleting $STACK_NAME"
  BUCKET=$(aws_ cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text 2>/dev/null || true)
  [ -n "${BUCKET:-}" ] && [ "$BUCKET" != "None" ] && aws_ s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true
  aws_ cloudformation delete-stack --stack-name "$STACK_NAME" >/dev/null 2>&1 || true
  aws_ cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" 2>/dev/null || true
  log "Teardown complete"
}
trap teardown EXIT

# The template is >51,200 B, so `cloudformation deploy` needs an S3 staging bucket.
ACCOUNT=$(aws_ sts get-caller-identity --query Account --output text)
S3_BUCKET="${S3_BUCKET:-cf-templates-flyte-devbox-${ACCOUNT}-${REGION}}"
aws_ s3api head-bucket --bucket "$S3_BUCKET" 2>/dev/null || aws_ s3 mb "s3://$S3_BUCKET" >/dev/null

log "Deploying $STACK_NAME ($DOMAIN) — Prod mode"
# Clean any prior instance of this throwaway stack first (so CREATE is valid).
if aws_ cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
  aws_ cloudformation delete-stack --stack-name "$STACK_NAME"
  aws_ cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" 2>/dev/null || true
fi
# Use a create-change-set + execute (more robust than `cloudformation deploy`,
# whose early-validation hook is flaky); template is >51 KB so stage it in S3.
aws_ s3 cp "$TEMPLATE" "s3://$S3_BUCKET/smoke-${STACK_NAME}.yaml" >/dev/null
aws_ cloudformation create-change-set --stack-name "$STACK_NAME" --change-set-name smoke \
  --change-set-type CREATE --capabilities CAPABILITY_NAMED_IAM \
  --template-url "https://${S3_BUCKET}.s3.${REGION}.amazonaws.com/smoke-${STACK_NAME}.yaml" \
  --parameters ParameterKey=Domain,ParameterValue="$DOMAIN" \
    ParameterKey=AllowedCidr,ParameterValue=0.0.0.0/0 \
    ParameterKey=AutoStop,ParameterValue=No \
    ParameterKey=AmiId,ParameterValue="${AMI_ID:-}" >/dev/null
aws_ cloudformation wait change-set-create-complete --stack-name "$STACK_NAME" --change-set-name smoke
aws_ cloudformation execute-change-set --stack-name "$STACK_NAME" --change-set-name smoke
aws_ cloudformation wait stack-create-complete --stack-name "$STACK_NAME"

ENDPOINT="dns:///${DOMAIN}:443"
POOL=$(aws_ cloudformation describe-stacks --stack-name "$STACK_NAME" --query "Stacks[0].Outputs[?OutputKey=='CognitoUserPoolId'].OutputValue" --output text)
M2M=$(aws_ cloudformation describe-stacks --stack-name "$STACK_NAME" --query "Stacks[0].Outputs[?OutputKey=='CognitoM2MClientId'].OutputValue" --output text)
COG_DOMAIN="https://${STACK_NAME}-${ACCOUNT}.auth.${REGION}.amazoncognito.com"
SECRET=$(aws_ cognito-idp describe-user-pool-client --user-pool-id "$POOL" --client-id "$M2M" --query "UserPoolClient.ClientSecret" --output text)

log "Waiting for the devbox to answer authenticated gRPC (cold boot ~5 min)"
TOK=""
for i in $(seq 1 60); do
  TOK=$(curl -s -X POST "$COG_DOMAIN/oauth2/token" -u "$M2M:$SECRET" \
        -d "grant_type=client_credentials&scope=https://${DOMAIN}/access" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null || true)
  if [ -n "$TOK" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
      "https://${DOMAIN}/flyteidl2.project.ProjectService/ListProjects" \
      -H "content-type: application/proto" -H "authorization: Bearer $TOK" --data-binary "" || true)
    echo "  attempt $i: ListProjects -> $code"
    [ "$code" = "200" ] && break
  fi
  sleep 15
done
[ "${code:-}" = "200" ] || { echo "devbox never became healthy"; exit 1; }

log "Running a workflow via M2M auth"
WORK="$(mktemp -d)"; cat > "$WORK/hello.py" <<'PY'
import flyte
env = flyte.TaskEnvironment(name="smoke")
@env.task
def main() -> str:
    return "smoke ok"
PY
cat > "$WORK/.config.yaml" <<YAML
admin:
  authType: ExternalCommand
  command: ["echo", "$TOK"]
  endpoint: $ENDPOINT
image:
  builder: local
task:
  project: flytesnacks
  domain: development
YAML

FLYTE="${FLYTE_BIN:-flyte}"
# On a brand-new box the data-proxy/storage subsystem can lag a little behind the
# API answering ListProjects, so give it a warm-up buffer + retry the run.
log "Warming up before run..."
sleep 45
OK=0
for attempt in 1 2 3 4; do
  OUT=$(cd "$WORK" && "$FLYTE" --config .config.yaml run hello.py main 2>&1) || true
  if echo "$OUT" | grep -q "Created Run:"; then OK=1; break; fi
  echo "  run attempt $attempt did not create a run; retrying in 20s"
  echo "$OUT" | sed 's/\x1b\[[0-9;]*m//g' | tail -4
  sleep 20
done
echo "$OUT" | sed 's/\x1b\[[0-9;]*m//g' | tail -8
if [ "$OK" = 1 ]; then
  log "✅ SMOKE PASSED — run created"
else
  log "❌ SMOKE FAILED — no run created after retries"; exit 1
fi
