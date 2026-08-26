#!/bin/bash

set -euo pipefail

required_variables=(
  AWS_PROFILE
  AWS_ACCOUNT_ID
  AWS_REGION
  DOMAIN_NAME
  VPC_CIDR
  VPC_AVAILABILITY_ZONES
  VPC_PUBLIC_SUBNETS
  VPC_PRIVATE_SUBNETS
  VPC_ELASTICACHE_SUBNETS
  PRIVATELINK_ALLOWED_PRINCIPAL_ARNS
)

missing_variables=()
for variable_name in "${required_variables[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    missing_variables+=("$variable_name")
  fi
done

if [[ ${#missing_variables[@]} -gt 0 ]]; then
  echo "Missing required variables: ${missing_variables[*]}"
  exit 1
fi

if [[ -n "${TF:-}" ]]; then
  iac_command="$TF"
elif command -v tofu >/dev/null 2>&1; then
  iac_command="tofu"
else
  iac_command="terraform"
fi

required_commands=(aws jq "$iac_command" packer docker go npm make)
for command_name in "${required_commands[@]}"; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name"
    exit 1
  fi
done

echo "Using $iac_command for infrastructure commands"

actual_account=$(aws sts get-caller-identity \
  --profile "$AWS_PROFILE" \
  --query Account \
  --output text)
if [[ "$actual_account" != "$AWS_ACCOUNT_ID" ]]; then
  echo "AWS profile $AWS_PROFILE resolves to $actual_account, expected $AWS_ACCOUNT_ID"
  exit 1
fi

for json_variable in \
  VPC_AVAILABILITY_ZONES \
  VPC_PUBLIC_SUBNETS \
  VPC_PRIVATE_SUBNETS \
  VPC_ELASTICACHE_SUBNETS \
  PRIVATELINK_ALLOWED_PRINCIPAL_ARNS; do
  if ! jq -e 'type == "array" and length > 0' <<<"${!json_variable}" >/dev/null; then
    echo "$json_variable must be a non-empty JSON array"
    exit 1
  fi
done

for json_variable in POSTGRES_ADMIN_INGRESS_SECURITY_GROUP_IDS; do
  json_value="${!json_variable:-[]}"
  if ! jq -e 'type == "array"' <<<"$json_value" >/dev/null; then
    echo "$json_variable must be a JSON array"
    exit 1
  fi
done

for security_group_variable in POSTGRES_ADMIN_INGRESS_SECURITY_GROUP_IDS; do
  security_group_values="${!security_group_variable:-[]}"
  if ! jq -e 'all(.[]; type == "string" and test("^sg-[0-9a-f]+$"))' <<<"$security_group_values" >/dev/null; then
    echo "$security_group_variable must contain only security group IDs"
    exit 1
  fi
done

if ! jq -e 'all(.[]; type == "string" and test("^arn:aws[a-zA-Z-]*:iam::[0-9]{12}:(root|role/.+)$"))' <<<"$PRIVATELINK_ALLOWED_PRINCIPAL_ARNS" >/dev/null; then
  echo "PRIVATELINK_ALLOWED_PRINCIPAL_ARNS must contain only IAM root or role ARNs"
  exit 1
fi

if [[ -n "${INGRESS_CERTIFICATE_VALIDATION_ZONE_ID:-}" ]]; then
  hosted_zone_json=$(aws route53 get-hosted-zone \
    --profile "$AWS_PROFILE" \
    --id "$INGRESS_CERTIFICATE_VALIDATION_ZONE_ID" \
    --output json)
  if [[ $(jq -r '.HostedZone.Config.PrivateZone' <<<"$hosted_zone_json") == "true" ]]; then
    echo "INGRESS_CERTIFICATE_VALIDATION_ZONE_ID must identify a public hosted zone"
    exit 1
  fi

  hosted_zone_name=$(jq -r '.HostedZone.Name' <<<"$hosted_zone_json")
  hosted_zone_name="${hosted_zone_name%.}"
  if [[ "$DOMAIN_NAME" != "$hosted_zone_name" && "$DOMAIN_NAME" != *".$hosted_zone_name" ]]; then
    echo "Public hosted zone $hosted_zone_name is not authoritative for $DOMAIN_NAME"
    exit 1
  fi
fi

for instance_type in \
  "${CLIENT_SERVER_MACHINE_TYPE:-m8i.4xlarge}" \
  "${BUILD_SERVER_MACHINE_TYPE:-m8i.4xlarge}"; do
  offering_count=$(aws ec2 describe-instance-type-offerings \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --location-type region \
    --filters "Name=instance-type,Values=$instance_type" \
    --query 'length(InstanceTypeOfferings)' \
    --output text)
  if [[ "$offering_count" == "0" ]]; then
    echo "Instance type $instance_type is not offered in $AWS_REGION"
    exit 1
  fi
done

if [[ -n "${INGRESS_CERTIFICATE_ARN:-}" ]]; then
  certificate_status=$(aws acm describe-certificate \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --certificate-arn "$INGRESS_CERTIFICATE_ARN" \
    --query 'Certificate.Status' \
    --output text)
  if [[ "$certificate_status" != "ISSUED" ]]; then
    echo "Ingress certificate status is $certificate_status, expected ISSUED"
    exit 1
  fi
else
  if [[ -n "${INGRESS_CERTIFICATE_VALIDATION_ZONE_ID:-}" ]]; then
    echo "Terraform will request and validate the ingress certificate in public Route53 zone $INGRESS_CERTIFICATE_VALIDATION_ZONE_ID"
  else
    echo "No existing ingress certificate or public Route53 zone configured; run make request-certificate after make init and publish its validation record"
  fi
fi

echo "AWS shared private deployment preflight passed for account $AWS_ACCOUNT_ID in $AWS_REGION"
