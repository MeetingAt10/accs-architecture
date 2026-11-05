#!/usr/bin/env bash
# Deploy only the ACCS portal and API: never the landing or meeting sites.
# SKIP_STACK=1 skips the backend build and stack deploy (sites only).
# SESSION_SECRET (optional env) is inlined into a new Lambda bundle like the backend CI does. Without it the
# script keeps the current API code (normally the CI build) and only updates the stack. Never printed.
set -euo pipefail

export AWS_PROFILE=${AWS_PROFILE:-meetingatten}
export AWS_REGION=${AWS_REGION:-ap-southeast-1}
STACK=${STACK:-accs-dev}

ARCH=$(cd "$(dirname "$0")/.." && pwd)
SYSTEM=$(dirname "$ARCH")
BACKEND=${BACKEND_DIR:-$SYSTEM/backend}
FRONTEND=${FRONTEND_DIR:-$SYSTEM/frontend}

P=(); command -v pcore >/dev/null && P=(pcore)

out() { aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

if [ -z "${SKIP_STACK:-}" ]; then
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
  ARTIFACTS="$STACK-artifacts-$ACCOUNT"
  aws s3api head-bucket --bucket "$ARTIFACTS" 2>/dev/null ||
    aws s3 mb "s3://$ARTIFACTS" --region "$AWS_REGION"

  CODE_OVERRIDES=()
  if [ -n "${SESSION_SECRET:-}" ]; then
    echo "== backend"
    (cd "$BACKEND" && "${P[@]}" npm ci && "${P[@]}" npm run build:lambda -- --define:process.env.SESSION_SECRET="\"$SESSION_SECRET\"")
    ZIP=$(mktemp -d)/api.zip
    (cd "$BACKEND/dist-lambda" && zip -qj "$ZIP" index.cjs)
    KEY="api/$(sha256sum "$ZIP" | cut -c1-16).zip"
    aws s3 cp "$ZIP" "s3://$ARTIFACTS/$KEY"
    CODE_OVERRIDES=(--parameter-overrides ApiCodeBucket="$ARTIFACTS" ApiCodeKey="$KEY")
  else
    echo "SESSION_SECRET not set: keeping the current API code, updating the stack only" >&2
  fi

  echo "== stack"
  cd "$ARCH/cloudformation"
  aws cloudformation package --template-file envs/dev/main.yaml \
    --s3-bucket "$ARTIFACTS" --s3-prefix templates --output-template-file packaged-dev.yaml
  aws cloudformation deploy --template-file packaged-dev.yaml --stack-name "$STACK" \
    --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset \
    "${CODE_OVERRIDES[@]}" \
    --tags Project=accs Environment=dev ManagedBy=cloudformation
fi

echo "== frontend"
(cd "$FRONTEND" && "${P[@]}" npm ci)
(cd "$FRONTEND" && rm -rf dist && VITE_API_URL="$(out ApiUrl)/api" "${P[@]}" npm run build)
aws s3 sync "$FRONTEND/dist" "s3://$(out AppBucket)" --delete
aws cloudfront create-invalidation --distribution-id "$(out AppDistributionId)" --paths '/*' >/dev/null

echo
printf '%-12s %s\n' AppUrl "$(out AppUrl)"
printf '%-12s %s\n' ApiUrl "$(out ApiUrl)"
