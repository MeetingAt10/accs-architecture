#!/usr/bin/env bash
# One-off: create the media CDN's signing key pair (CloudFront signed URLs for post pictures and videos).
# The private key goes straight into an SSM SecureString and is deleted locally; it is never printed.
# The public key is written to the file given (default media-public-key.pem) for the MediaPublicKey stack parameter:
#   scripts/media-signing-key.sh
#   aws cloudformation deploy ... --parameter-overrides MediaPublicKey="$(cat media-public-key.pem)"   (or deploy-dev.sh with MEDIA_PUBLIC_KEY_FILE)
# Refuses to replace an existing key; set ROTATE=1 to overwrite it (then redeploy with the new public key at once,
# or signed links fail until you do).
set -euo pipefail

export AWS_PROFILE=${AWS_PROFILE:-meetingatten}
export AWS_REGION=${AWS_REGION:-ap-southeast-1}
STACK=${STACK:-accs-dev}
ENV_NAME=${STACK#accs-}
PARAM=${PARAM:-/accs/$ENV_NAME/media-signing-key}
OUT=${1:-media-public-key.pem}

if aws ssm get-parameter --name "$PARAM" --query Parameter.Name --output text >/dev/null 2>&1 && [ "${ROTATE:-}" != 1 ]; then
  echo "$PARAM already exists. Set ROTATE=1 to replace it." >&2
  exit 1
fi

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
umask 077
openssl genrsa -out "$DIR/private.pem" 2048 2>/dev/null
openssl rsa -pubout -in "$DIR/private.pem" -out "$OUT" 2>/dev/null
# file:// keeps the key out of the process list and shell history.
aws ssm put-parameter --name "$PARAM" --type SecureString --overwrite --value "file://$DIR/private.pem" \
  --description "CloudFront media signing key ($STACK); public key is the MediaPublicKey stack parameter" >/dev/null
echo "Private key stored in $PARAM. Public key written to $OUT."
