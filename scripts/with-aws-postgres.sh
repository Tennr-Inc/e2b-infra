#!/bin/bash

set -euo pipefail

: "${AWS_PROFILE:?AWS_PROFILE is required}"
: "${AWS_REGION:?AWS_REGION is required}"
: "${POSTGRES_CONNECTION_STRING_SECRET_NAME:?POSTGRES_CONNECTION_STRING_SECRET_NAME is required}"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <command> [args...]"
  exit 1
fi

POSTGRES_CONNECTION_STRING=$(aws secretsmanager get-secret-value \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --secret-id "$POSTGRES_CONNECTION_STRING_SECRET_NAME" \
  --query SecretString \
  --output text)

if [[ -z "$POSTGRES_CONNECTION_STRING" || "$POSTGRES_CONNECTION_STRING" == "None" ]]; then
  echo "PostgreSQL connection string secret is empty: $POSTGRES_CONNECTION_STRING_SECRET_NAME"
  exit 1
fi

export POSTGRES_CONNECTION_STRING
exec "$@"
