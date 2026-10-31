#!/usr/bin/env bash
# Build all apps, deploy the accs-dev stack, upload the sites.
# Expects sibling checkouts: accs-system/{architecture,backend,frontend}, ../accs-landing, ../meeting@10-website.
set -euo pipefail

export AWS_PROFILE=${AWS_PROFILE:-meetingatten}
export AWS_REGION=${AWS_REGION:-ap-southeast-1}
STACK=${STACK:-accs-dev}

ARCH=$(cd "$(dirname "$0")/.." && pwd)
SYSTEM=$(dirname "$ARCH")
CAPSTONE=$(dirname "$SYSTEM")
BACKEND=${BACKEND_DIR:-$SYSTEM/backend}
FRONTEND=${FRONTEND_DIR:-$SYSTEM/frontend}
LANDING=${LANDING_DIR:-$CAPSTONE/accs-landing}
MEETING=${MEETING_DIR:-$CAPSTONE/meeting@10-website}

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ARTIFACTS="$STACK-artifacts-$ACCOUNT"
aws s3api head-bucket --bucket "$ARTIFACTS" 2>/dev/null ||
  aws s3 mb "s3://$ARTIFACTS" --region "$AWS_REGION"

echo "== backend"
(cd "$BACKEND" && npm ci && npm run build:lambda)
ZIP=$(mktemp -d)/api.zip
(cd "$BACKEND/dist-lambda" && zip -qj "$ZIP" index.cjs)
KEY="api/$(sha256sum "$ZIP" | cut -c1-16).zip"
aws s3 cp "$ZIP" "s3://$ARTIFACTS/$KEY"

echo "== stack"
cd "$ARCH/cloudformation"
aws cloudformation package --template-file envs/dev/main.yaml \
  --s3-bucket "$ARTIFACTS" --s3-prefix templates --output-template-file packaged-dev.yaml
aws cloudformation deploy --template-file packaged-dev.yaml --stack-name "$STACK" \
  --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset \
  --parameter-overrides ApiCodeBucket="$ARTIFACTS" ApiCodeKey="$KEY" \
  --tags Project=accs Environment=dev ManagedBy=cloudformation

out() { aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

publish() { # dir build-subdir output-prefix
  echo "== $1"
  rm -rf "${1:?}/$2" "$1/.next" # a stale Turbopack cache can ship old CSS
  (cd "$1" && npm ci && npm run build)
  aws s3 sync "$1/$2" "s3://$(out "$3Bucket")" --delete
  aws cloudfront create-invalidation --distribution-id "$(out "$3DistributionId")" --paths '/*' >/dev/null
}

publish "$LANDING" out Landing
publish "$MEETING" out Meeting
VITE_SITE_ORIGINS="$(out SiteOrigins)" publish "$FRONTEND" dist App
for p in Forums Schedule Cases Evaluations Records Admin; do # module sites serve the same build
  aws s3 sync "$FRONTEND/dist" "s3://$(out "${p}Bucket")" --delete
  aws cloudfront create-invalidation --distribution-id "$(out "${p}DistributionId")" --paths '/*' >/dev/null
done

echo
for k in LandingUrl MeetingUrl AppUrl ForumsUrl ScheduleUrl CasesUrl EvaluationsUrl RecordsUrl AdminUrl ApiUrl; do printf '%-14s %s\n' "$k" "$(out $k)"; done
