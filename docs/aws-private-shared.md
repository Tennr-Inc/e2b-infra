# Shared private AWS deployment

This runbook deploys one E2B cluster into a dedicated AWS account and exposes it privately to
Tennr's staging and production accounts through AWS PrivateLink. Staging and production are
separate E2B teams in the same cluster; they do not require duplicate infrastructure.

No E2B hostname is publicly routable. Public DNS is used only for the ACM ownership-validation
CNAME. Sandboxes and cluster nodes retain outbound internet access through a NAT gateway.

This is a command-oriented runbook. Run each command yourself from the repository root unless a
section explicitly changes directories. Commands that mutate AWS are separated from read-only
checks so that every plan and account identity can be reviewed before an apply.

The required order is:

1. bootstrap the E2B account network and keys;
2. deploy an E2B-account Twingate connector for the private RDS bootstrap path;
3. issue the certificate and publish images;
4. apply E2B infrastructure **without** Nomad jobs;
5. create the interface endpoint and private DNS in the consumer VPC;
6. configure Twingate and verify `nomad.${DOMAIN_NAME}` is reachable; and
7. create a fresh full plan, apply the Nomad jobs, and seed the teams.

The full plan cannot run until steps 5 and 6 are complete because the OpenTofu Nomad provider
connects to the private Nomad hostname through the production endpoint and Twingate.

## Architecture and account ownership

The E2B account owns:

- the E2B VPC and its public NAT, private workload, and isolated data subnets;
- Nomad/Consul, Firecracker clients, template builders, API nodes, and ClickHouse;
- private RDS PostgreSQL and managed Valkey;
- an internal HTTPS ALB;
- an internal NLB and VPC endpoint service in front of that ALB;
- the provider-side private Route53 zone;
- three rotating customer-managed KMS keys for EBS, RDS, and S3; and
- the E2B application buckets, repositories, and secrets.

Each Tennr consumer account owns:

- an interface endpoint in the VPC that needs E2B;
- an endpoint security group allowing only approved workloads and private-access connectors; and
- a private Route53 zone for the shared E2B domain, whose wildcard aliases the local endpoint.

The same hostname therefore resolves to the staging endpoint inside staging and to the production
endpoint inside production. PrivateLink does not exchange routes between the VPCs and does not let
E2B initiate connections into either Tennr account.

Public subnets and an internet gateway remain because an AWS NAT gateway requires them. E2B nodes
and services stay in private subnets and receive no public IP addresses.

## 1. Create access and prepare the E2B account

The dedicated AWS account and the human or CI deployment role are prerequisites; this repository
does not create either one. Create them through Tennr's normal AWS Organizations and identity
process. The AWS account's display name, the permission-set or role name, and each operator's local
AWS CLI profile alias are intentionally not prescribed by this runbook.

The initial deployment identity must be able to create and pass the IAM roles used by E2B and
manage EC2, VPC, PrivateLink, Route53, ACM, KMS, RDS, ElastiCache, ECR, S3, Secrets Manager, Auto
Scaling, and load-balancing resources. Have the cloud-security owner provision that access under
the organization's normal guardrails. The application and EC2 roles created by this repository
remain namespaced by `PREFIX`; they are different from the operator's deployment role.

Before continuing:

1. create the dedicated AWS account under the appropriate organization/OU;
2. provision an operator permission set or role with the required deployment permissions;
3. assign the operators who will bootstrap and maintain E2B;
4. configure an arbitrary local AWS CLI profile alias for that access; and
5. identify the existing production account and obtain an arbitrary local profile for it.

Install OpenTofu, AWS CLI v2, `jq`, Packer, Docker, Go, Node.js/npm, GNU Make, the Nomad CLI, and
`kubectl` locally.

Choose local profile aliases. The strings assigned below are local configuration, not required AWS
account or role names:

```sh
cd /path/to/e2b-infra
git switch main
git pull --ff-only origin main

export E2B_PROFILE=REPLACE_WITH_LOCAL_E2B_PROFILE
export PRODUCTION_PROFILE=REPLACE_WITH_LOCAL_PRODUCTION_PROFILE
```

If the local profiles do not exist yet, configure each one using the SSO start URL, SSO region,
account, and permission set supplied by the identity administrator:

```sh
aws configure sso --profile "$E2B_PROFILE"
aws configure sso --profile "$PRODUCTION_PROFILE"
```

Authenticate and discover the real account IDs rather than copying an account number from this
runbook:

```sh
aws sso login --profile "$E2B_PROFILE"
export E2B_ACCOUNT_ID=$(aws sts get-caller-identity \
  --profile "$E2B_PROFILE" \
  --query Account \
  --output text)

aws sso login --profile "$PRODUCTION_PROFILE"
export PRODUCTION_ACCOUNT_ID=$(aws sts get-caller-identity \
  --profile "$PRODUCTION_PROFILE" \
  --query Account \
  --output text)

printf 'E2B profile/account: %s / %s\nProduction profile/account: %s / %s\n' \
  "$E2B_PROFILE" \
  "$E2B_ACCOUNT_ID" \
  "$PRODUCTION_PROFILE" \
  "$PRODUCTION_ACCOUNT_ID"
```

Only configure a staging consumer if staging will receive its own PrivateLink endpoint. Its account
and role names are likewise operator-supplied:

```sh
export STAGING_PROFILE=REPLACE_WITH_LOCAL_STAGING_PROFILE
aws sso login --profile "$STAGING_PROFILE"
export STAGING_ACCOUNT_ID=$(aws sts get-caller-identity \
  --profile "$STAGING_PROFILE" \
  --query Account \
  --output text)

printf 'Staging profile/account: %s / %s\n' "$STAGING_PROFILE" "$STAGING_ACCOUNT_ID"
```

Choose a VPC CIDR that does not overlap any Tennr network. PrivateLink does not route the E2B CIDR
into consumer accounts, but a non-overlapping range avoids future operational problems.

## 2. Create the shared environment file

Environment files are ignored by Git:

```sh
cp .env.aws.template .env.shared
make set-env ENV=shared
```

Populate `.env.shared` with the dedicated E2B account and the production consumer account. Profile
aliases and account IDs must be the values discovered in the previous section:

```sh
PROVIDER=aws
AWS_PROFILE=REPLACE_WITH_LOCAL_E2B_PROFILE
AWS_ACCOUNT_ID=REPLACE_WITH_E2B_ACCOUNT_ID
AWS_REGION=us-east-1

PREFIX=e2b-shared-
TERRAFORM_ENVIRONMENT=shared
DOMAIN_NAME=e2b.internal.tennr.com

PRIVATELINK_ALLOWED_PRINCIPAL_ARNS='["arn:aws:iam::PRODUCTION_ACCOUNT_ID:root"]'

INGRESS_CERTIFICATE_ARN=
INGRESS_CERTIFICATE_VALIDATION_ZONE_ID=REPLACE_WITH_PUBLIC_ZONE_ID_OR_LEAVE_EMPTY

VPC_CIDR=10.40.0.0/16
VPC_AVAILABILITY_ZONES='["us-east-1a","us-east-1b","us-east-1c"]'
VPC_PUBLIC_SUBNETS='["10.40.0.0/24","10.40.1.0/24","10.40.2.0/24"]'
VPC_PRIVATE_SUBNETS='["10.40.10.0/24","10.40.11.0/24","10.40.12.0/24"]'
VPC_ELASTICACHE_SUBNETS='["10.40.20.0/24","10.40.21.0/24","10.40.22.0/24"]'

KMS_KEY_DELETION_WINDOW_DAYS=30
ENABLE_LOAD_BALANCER_DELETION_PROTECTION=true
USE_INSTANCE_CONNECT=true

REDIS_MANAGED=true
REDIS_INSTANCE_TYPE=cache.t4g.small
REDIS_REPLICA_SIZE=2

POSTGRES_ENGINE_VERSION=16.11
POSTGRES_ADMIN_INGRESS_SECURITY_GROUP_IDS='[]'
POSTGRES_INSTANCE_CLASS=db.t4g.small
POSTGRES_ALLOCATED_STORAGE=20
POSTGRES_MAX_ALLOCATED_STORAGE=100
POSTGRES_MULTI_AZ=true
POSTGRES_BACKUP_RETENTION_PERIOD=7
POSTGRES_DELETION_PROTECTION=true
POSTGRES_SKIP_FINAL_SNAPSHOT=false

# Template builds may request up to 24 GiB. A 64 GiB build host leaves room for
# Firecracker huge pages, template-manager, Nomad, and host services.
BUILD_SERVER_MACHINE_TYPE=m8i.4xlarge

ALLOW_SANDBOX_INTERNAL_CIDRS=
```

The base project tier is migrated to these effective template-build limits when the API database
migrator runs:

- `max_ram_mb = 24576` (24 GiB);
- `default_free_disk_size_mb = 15360` (15 GiB); and
- `max_disk_size_mb = 51200` (50 GiB).

Explicit project-limit rows are raised to the same floors, so an existing override cannot silently
retain the old values. The API uses `default_free_disk_size_mb` for new builds when the SDK does not
offer a disk option. For the large Tennr Tot template, request `memoryMB: 16384`; the extra memory is
useful for install/build commands, while COPY staging itself uses the rootfs rather than `/tmp`.

If staging later receives its own endpoint, append
`"arn:aws:iam::${STAGING_ACCOUNT_ID}:root"` to
`PRIVATELINK_ALLOWED_PRINCIPAL_ARNS`. Do not invent or preconfigure a staging account ID.

Use one stable domain such as `e2b.internal.tennr.com`; do not put `staging` or `prod` in the
cluster domain. Team API keys provide the environment boundary.

Run the read-only preflight:

```sh
make aws-private-preflight
```

The `shared` environment is protected by `scripts/confirm.sh`. Mutating Make targets must run from
`main` and prompt for the word `production`; this protects the shared production-bearing cluster
even though the environment is named `shared`.

## 3. Bootstrap state, networking, buckets, and keys

Run:

```sh
make init TF=tofu
```

This creates the state bucket if needed, initializes the backend, and applies `module.init`. The
module creates the VPC, NAT path, AWS endpoints, ECR repositories, application buckets, secret
containers, and three customer-managed KMS keys:

- `alias/e2b-shared-ebs`
- `alias/e2b-shared-rds`
- `alias/e2b-shared-s3`

Key rotation is enabled. `make init` changes the state bucket's default encryption to the S3 CMK
after that key exists. The initial bootstrap state version is necessarily written before the key is
available; later state versions use SSE-KMS. Application buckets use the S3 CMK from creation. ALB
access logs retain SSE-S3 because the ALB log-delivery integration has separate encryption support.

Record the outputs:

```sh
tofu -chdir=iac/provider-aws output -raw vpc_id
tofu -chdir=iac/provider-aws output -json vpc_private_subnet_ids
tofu -chdir=iac/provider-aws output -raw ebs_kms_key_arn
tofu -chdir=iac/provider-aws output -raw rds_kms_key_arn
tofu -chdir=iac/provider-aws output -raw s3_kms_key_arn
```

## 4. Deploy the E2B-account Twingate connector

The production VPC connector reaches the E2B HTTPS service through PrivateLink, but it cannot reach
RDS. The current `make seed-db` command runs on the operator's laptop and connects directly to the
private RDS endpoint, so the bootstrap path also needs a Connector in the E2B VPC.

`e2b-infra` does not create Twingate control-plane objects or Connector tokens. Create an `E2B
Shared AWS` Remote Network in the Twingate Admin Console, add a Connector to it, choose the official
AWS ECS/Fargate deployment, and generate a unique token pair for that Connector. For production
availability, create two Connectors with different token pairs; never reuse Connector tokens.

Use the VPC and a private subnet created by `make init`. Re-export the operator-chosen local E2B
profile if this is a new shell:

```sh
export E2B_PROFILE=REPLACE_WITH_LOCAL_E2B_PROFILE
export AWS_PROFILE="$E2B_PROFILE"
export AWS_REGION=us-east-1
export E2B_VPC_ID=$(tofu -chdir=iac/provider-aws output -raw vpc_id)
export E2B_CONNECTOR_SUBNET_ID=$(tofu -chdir=iac/provider-aws \
  output -json vpc_private_subnet_ids | jq -r '.[0]')

printf 'VPC: %s\nConnector subnet: %s\n' \
  "$E2B_VPC_ID" \
  "$E2B_CONNECTOR_SUBNET_ID"
```

Create a dedicated Connector security group. It needs no inbound rules. A newly created AWS
security group permits outbound traffic; the Connector uses the private subnet's NAT path to reach
Twingate:

```sh
export E2B_CONNECTOR_SG_ID=$(aws ec2 create-security-group \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --vpc-id "$E2B_VPC_ID" \
  --group-name e2b-shared-twingate-connector \
  --description 'Twingate connector for private E2B administration' \
  --query GroupId \
  --output text)

aws ec2 create-tags \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --resources "$E2B_CONNECTOR_SG_ID" \
  --tags Key=Name,Value=e2b-shared-twingate-connector

printf 'Connector security group: %s\n' "$E2B_CONNECTOR_SG_ID"
```

In the Twingate ECS deployment screen, provide the discovered E2B account ID, region, private
subnet, and this security group. Run the generated `aws ecs register-task-definition` and
`aws ecs create-service` commands using `--profile "$E2B_PROFILE" --region "$AWS_REGION"`.
Connector tokens are credentials: do not
commit the generated task definition or paste its tokens into tickets or logs. Prefer the existing
Tennr ECS Connector pattern that injects them from Secrets Manager.

Check AWS after running the generated commands:

```sh
export E2B_TWINGATE_ECS_CLUSTER=REPLACE_ME
export E2B_TWINGATE_ECS_SERVICE=REPLACE_ME

aws ecs wait services-stable \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --cluster "$E2B_TWINGATE_ECS_CLUSTER" \
  --services "$E2B_TWINGATE_ECS_SERVICE"

aws ecs describe-services \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --cluster "$E2B_TWINGATE_ECS_CLUSTER" \
  --services "$E2B_TWINGATE_ECS_SERVICE" \
  --query 'services[0].{Status:status,Desired:desiredCount,Running:runningCount,Events:events[0:3].message}'
```

Confirm the Connector is `Connected` in Twingate. Add its security group to `.env.shared` before
creating the infrastructure-only plan:

```sh
POSTGRES_ADMIN_INGRESS_SECURITY_GROUP_IDS='["sg-REPLACE_WITH_E2B_CONNECTOR_SG"]'
```

This creates a single RDS rule from the Connector security group on TCP 5432. It does not open RDS
to the VPC CIDR or the internet.

## 5. Issue the wildcard certificate

The ACM certificate must be in `AWS_REGION` and cover `*.${DOMAIN_NAME}`. The certificate
terminates TLS on the internal ALB; it does not make the ALB public.

To reuse an issued certificate, set `INGRESS_CERTIFICATE_ARN`. Otherwise leave it empty and run:

```sh
make request-certificate TF=tofu
make certificate-validation-records TF=tofu
```

If `INGRESS_CERTIFICATE_VALIDATION_ZONE_ID` is a public Route53 zone, OpenTofu manages the CNAME.
For an external DNS provider, publish the reported CNAME in authoritative **public** DNS with proxying
disabled. A private hosted zone cannot validate ACM ownership. Keep the CNAME permanently so ACM
can renew the certificate.

Wait until ACM reports `ISSUED` before creating the ALB listener.

Check the exact certificate status:

```sh
export INGRESS_CERTIFICATE_ARN=$(tofu -chdir=iac/provider-aws \
  output -raw ingress_certificate_arn)

aws acm describe-certificate \
  --profile "$E2B_PROFILE" \
  --region "$AWS_REGION" \
  --certificate-arn "$INGRESS_CERTIFICATE_ARN" \
  --query 'Certificate.{Status:Status,FailureReason:FailureReason,Validation:DomainValidationOptions[*].{Domain:DomainName,Status:ValidationStatus,Name:ResourceRecord.Name,Value:ResourceRecord.Value}}'
```

## 6. Build and publish artifacts

Authenticate Docker and build the KMS-encrypted Nomad AMI after `make init` has created the EBS key:

```sh
make provider-login
make -C iac/provider-aws/nomad-cluster-disk-image init
make -C iac/provider-aws/nomad-cluster-disk-image build
```

The Packer Makefile reads `ebs_kms_key_arn` from OpenTofu output. It refuses to build before the key
exists.

Publish the E2B components and public Firecracker artifacts:

```sh
make build-and-upload
make copy-public-builds
```

`build-and-upload` publishes API, client proxy, dashboard API, NFS cache cleaner, orchestrator,
template manager, envd, ClickHouse migrator, and Nomad node-pool APM artifacts. The API build also
publishes the matching `db-migrator` image containing the automatic `postgres` compatibility-role
bootstrap.

## 7. Create the cluster and endpoint service without Nomad jobs

Create and review the infrastructure-only plan:

```sh
make plan-without-jobs TF=tofu
tofu -chdir=iac/provider-aws show .tfplan.shared
```

Verify the plan contains:

- an internal ALB with HTTPS only;
- an internal NLB targeting the ALB on TCP 443;
- an endpoint service whose allowed principals are exactly the intended Tennr accounts;
- no VPC peering connections or consumer-account routes;
- EBS launch templates and ClickHouse data volumes using the EBS CMK;
- private RDS using the RDS CMK, TLS, Multi-AZ, backups, and deletion protection;
- application S3 buckets using the S3 CMK; and
- encrypted, private managed Valkey.

Apply the reviewed saved plan:

```sh
make apply TF=tofu
```

Record the service name that consumer accounts need:

```sh
export E2B_ENDPOINT_SERVICE_NAME=$(tofu -chdir=iac/provider-aws \
  output -raw privatelink_service_name)

printf '%s\n' "$E2B_ENDPOINT_SERVICE_NAME"
```

The endpoint service automatically accepts endpoints only from the explicitly allowed principals.
This removes a manual acceptance step without allowing arbitrary accounts to connect.

Record the RDS hostname:

```sh
export E2B_POSTGRES_ENDPOINT=$(tofu -chdir=iac/provider-aws \
  output -raw postgres_endpoint)

printf '%s\n' "$E2B_POSTGRES_ENDPOINT"
```

In the Twingate Admin Console, add a Resource to the `E2B Shared AWS` Remote Network with that exact
hostname, restrict it to TCP 5432, and grant it only to the infrastructure/database-administrator
group. The Resource must use the E2B Remote Network, not the production Remote Network, because RDS
is not exposed through PrivateLink.

## 8. Create the production interface endpoint

The endpoint, its security group, and consumer-side DNS belong to the infrastructure project that
owns the production VPC. The `deploy` repository contains Kubernetes/Twingate GitOps resources but
does not currently own AWS networking, so do not put the following OpenTofu state into `deploy`.

### 8.1 Collect production values

Export the service name printed in the previous section, then identify the production VPC, two
private subnets in different availability zones, and the security group attached to the production
Twingate connector:

```sh
export PRODUCTION_PROFILE=REPLACE_WITH_LOCAL_PRODUCTION_PROFILE
export AWS_PROFILE="$PRODUCTION_PROFILE"
export AWS_REGION=us-east-1
export E2B_DOMAIN=e2b.internal.tennr.com
export E2B_ENDPOINT_SERVICE_NAME='com.amazonaws.vpce.us-east-1.vpce-svc-REPLACE_ME'

aws sts get-caller-identity --profile "$AWS_PROFILE"

aws ec2 describe-vpcs \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --query 'Vpcs[*].{VpcId:VpcId,Cidr:CidrBlock,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table

aws ec2 describe-subnets \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --filters Name=vpc-id,Values=vpc-REPLACE_ME \
  --query 'Subnets[*].{SubnetId:SubnetId,AZ:AvailabilityZone,Cidr:CidrBlock,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table
```

If the connector runs as an ECS service, these commands locate the security group on its task ENI:

```sh
export TWINGATE_ECS_CLUSTER=REPLACE_ME
export TWINGATE_ECS_SERVICE=REPLACE_ME

export TWINGATE_TASK_ARN=$(aws ecs list-tasks \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --cluster "$TWINGATE_ECS_CLUSTER" \
  --service-name "$TWINGATE_ECS_SERVICE" \
  --desired-status RUNNING \
  --query 'taskArns[0]' \
  --output text)

export TWINGATE_ENI_ID=$(aws ecs describe-tasks \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --cluster "$TWINGATE_ECS_CLUSTER" \
  --tasks "$TWINGATE_TASK_ARN" \
  --query "tasks[0].attachments[?type=='ElasticNetworkInterface'].details[?name=='networkInterfaceId'].value | [0][0]" \
  --output text)

aws ec2 describe-network-interfaces \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --network-interface-ids "$TWINGATE_ENI_ID" \
  --query 'NetworkInterfaces[0].Groups[*].{Name:GroupName,Id:GroupId}' \
  --output table
```

Use the connector ENI security group, not the Twingate synthetic `100.x.x.x` client address and not
the entire production VPC CIDR. Add the security groups of production workloads that call E2B
directly to the same source list; those workloads connect to the interface endpoint without using
the human Twingate path.

Confirm that the E2B endpoint service is visible to the production account:

```sh
aws ec2 describe-vpc-endpoint-services \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --service-names "$E2B_ENDPOINT_SERVICE_NAME" \
  --query 'ServiceDetails[0].{Name:ServiceName,Owner:Owner,AcceptanceRequired:AcceptanceRequired,AZs:AvailabilityZones}' \
  --output table
```

An empty result or `ServiceNameNotFound` means the E2B endpoint service does not yet allow the
production account root ARN, or the profiles are using different regions.

### 8.2 Add the endpoint to the production AWS IaC project

Add the following to the OpenTofu project that already owns the production VPC. Replace the VPC and
subnet expressions with that project's outputs:

```hcl
variable "e2b_endpoint_service_name" {
  type = string
}

variable "e2b_endpoint_source_security_group_ids" {
  type = list(string)
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Use endpoint subnets in at least two availability zones."
  }
}

variable "e2b_domain" {
  type    = string
  default = "e2b.internal.tennr.com"
}

resource "aws_security_group" "e2b_endpoint" {
  name        = "e2b-interface-endpoint"
  description = "Private HTTPS access to the shared E2B cluster"
  vpc_id      = var.vpc_id

  tags = {
    Name = "e2b-interface-endpoint"
  }
}

resource "aws_vpc_security_group_ingress_rule" "e2b_endpoint_https" {
  for_each = toset(var.e2b_endpoint_source_security_group_ids)

  security_group_id            = aws_security_group.e2b_endpoint.id
  referenced_security_group_id = each.value
  description                  = "HTTPS from an approved workload or Twingate connector"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_endpoint" "e2b" {
  vpc_id              = var.vpc_id
  service_name        = var.e2b_endpoint_service_name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.e2b_endpoint.id]
  private_dns_enabled = false
}

resource "aws_route53_zone" "e2b" {
  name = var.e2b_domain

  vpc {
    vpc_id = var.vpc_id
  }
}

resource "aws_route53_record" "e2b_wildcard" {
  zone_id = aws_route53_zone.e2b.zone_id
  name    = "*.${var.e2b_domain}"
  type    = "A"

  alias {
    name                   = aws_vpc_endpoint.e2b.dns_entry[0].dns_name
    zone_id                = aws_vpc_endpoint.e2b.dns_entry[0].hosted_zone_id
    evaluate_target_health = false
  }
}

output "e2b_vpc_endpoint_id" {
  value = aws_vpc_endpoint.e2b.id
}

output "e2b_vpc_endpoint_state" {
  value = aws_vpc_endpoint.e2b.state
}

output "e2b_private_zone_id" {
  value = aws_route53_zone.e2b.zone_id
}
```

Set the values using the IDs collected above:

```hcl
e2b_endpoint_service_name = "com.amazonaws.vpce.us-east-1.vpce-svc-REPLACE_ME"
vpc_id                    = "vpc-REPLACE_ME"
private_subnet_ids        = ["subnet-REPLACE_A", "subnet-REPLACE_B"]
e2b_domain                = "e2b.internal.tennr.com"
e2b_endpoint_source_security_group_ids = [
  "sg-REPLACE_WITH_TWINGATE_CONNECTOR_SG",
]
```

Run the consumer project's normal validation and saved-plan workflow. In a plain OpenTofu project:

```sh
tofu fmt -recursive
tofu init
tofu validate
tofu plan -out=.tfplan.e2b-privatelink
tofu show .tfplan.e2b-privatelink
tofu apply .tfplan.e2b-privatelink
```

Verify the endpoint is available and DNS targets its endpoint ENIs:

```sh
export E2B_VPC_ENDPOINT_ID=$(tofu output -raw e2b_vpc_endpoint_id)

aws ec2 describe-vpc-endpoints \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --vpc-endpoint-ids "$E2B_VPC_ENDPOINT_ID" \
  --query 'VpcEndpoints[0].{State:State,Service:ServiceName,Subnets:SubnetIds,Groups:Groups[*].GroupId,DNS:DnsEntries[*].DnsName}'

aws route53 list-resource-record-sets \
  --profile "$AWS_PROFILE" \
  --hosted-zone-id "$(tofu output -raw e2b_private_zone_id)" \
  --query 'ResourceRecordSets[?Name==`*.e2b.internal.tennr.com.`]'
```

If the production project already has a suitable private hosted zone, create the wildcard record in
that zone instead of creating a duplicate zone. The important behavior is that the connector's VPC
resolver returns the local interface endpoint for `*.${E2B_DOMAIN}`.

### 8.3 Add the Twingate resources through `deploy`

The `deploy` repository already uses `TwingateResource` and `TwingateResourceAccess` objects in the
`twingate` namespace. Add a GitOps manifest using the same API version installed in the production
cluster. The wildcard is necessary because every sandbox receives a dynamic hostname:

```yaml
apiVersion: twingate.com/v1beta
kind: TwingateResource
metadata:
  name: e2b-shared
  namespace: twingate
spec:
  name: E2B Shared
  address: "*.e2b.internal.tennr.com"
  isBrowserShortcutEnabled: false
  isVisible: true
---
apiVersion: twingate.com/v1beta
kind: TwingateResourceAccess
metadata:
  name: e2b-shared-infrastructure
  namespace: twingate
spec:
  resourceRef:
    name: e2b-shared
    namespace: twingate
  principalExternalRef:
    type: group
    name: "REPLACE_WITH_INFRASTRUCTURE_GROUP"
```

Commit the manifest through the normal `deploy`/Argo CD workflow. Existing examples are rendered by
files such as `2jca3y/charts/tennr-core/templates/twingateresource.yaml`; either add the E2B objects
through an Argo-managed chart or create a small Argo-managed manifest directory. A loose YAML file
in the repository will not be applied automatically. After Argo syncs it, verify the operator
objects:

```sh
kubectl --context REPLACE_WITH_PROD_CONTEXT \
  -n twingate get twingateresource e2b-shared

kubectl --context REPLACE_WITH_PROD_CONTEXT \
  -n twingate get twingateresourceaccess e2b-shared-infrastructure
```

Twingate supports wildcard DNS resources. Do not rely on separate `api` or `nomad` Twingate entries
as a security boundary while the wildcard is granted to a broader group: the wildcard also matches
those names. Keep the wildcard restricted to infrastructure operators, require the E2B API key for
API calls, and require the Nomad ACL token for Nomad. Add specific `api` or `nomad` resources only
for display/access-policy purposes after reviewing the overlap.

On a connected laptop, Twingate normally returns a synthetic `100.96.0.0/12` address. That is
expected; the production connector resolves the real private DNS name and opens the connection to
the interface endpoint:

```sh
dscacheutil -q host -a name api.e2b.internal.tennr.com
dscacheutil -q host -a name nomad.e2b.internal.tennr.com

curl -sv --connect-timeout 10 https://api.e2b.internal.tennr.com/
curl -sv --connect-timeout 10 https://nomad.e2b.internal.tennr.com/
```

Before Nomad jobs exist, a completed TLS handshake followed by API `502` is expected. A TCP timeout
means Twingate routing, the endpoint security group, the endpoint state, or private DNS is wrong. A
TLS certificate mismatch means the request used the AWS endpoint DNS name instead of the E2B
hostname, or the ACM certificate does not cover the shared domain.

PrivateLink exposes the HTTPS service only. It does **not** expose RDS. The E2B-account connector
created in section 4 is the separate RDS administration path. Routine setup no longer requires a
manual `CREATE ROLE postgres` query because the migrator creates that historical compatibility
role automatically.

## 9. Deploy Nomad jobs

With Twingate connected through either consumer endpoint, verify the network and TLS path:

```sh
curl -sv --connect-timeout 10 https://api.${DOMAIN_NAME}/
curl -sv --connect-timeout 10 https://nomad.${DOMAIN_NAME}/
```

An API `502` is expected before the API job exists. A TCP or TLS timeout means the consumer endpoint
security group, DNS alias, Twingate resource, or connector selection is wrong.

Create a new full plan; do not reuse the infrastructure-only plan:

```sh
make plan TF=tofu
tofu -chdir=iac/provider-aws show .tfplan.shared
make apply TF=tofu
```

Authenticate to Nomad with the ACL token from `${PREFIX}cluster`, wait for jobs to become healthy,
and investigate failed allocations before creating teams.

Retrieve the token and verify Nomad without printing the token:

```sh
export E2B_PROFILE=REPLACE_WITH_LOCAL_E2B_PROFILE
export AWS_PROFILE="$E2B_PROFILE"
export AWS_REGION=us-east-1
export DOMAIN_NAME=e2b.internal.tennr.com
export PREFIX=e2b-shared-
export NOMAD_ADDR="https://nomad.${DOMAIN_NAME}"
export NOMAD_TOKEN=$(aws secretsmanager get-secret-value \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --secret-id "${PREFIX}cluster" \
  --query SecretString \
  --output text | jq -r '.NOMAD_ACL_TOKEN')

nomad status
nomad job status api
nomad alloc logs -job api db-migrator
nomad alloc logs -job api start
unset NOMAD_TOKEN
```

The API job's `db-migrator` prestart task creates the historical `postgres` compatibility role and
then applies Goose migrations. Its log must end with `Migrations applied successfully.` before
seeding teams.

## 10. Create separate staging and production teams

The cluster is shared, but teams are the data and quota boundary. Bootstrap two teams with distinct
names, slugs, and contact emails:

First verify the laptop can reach RDS through the E2B-account Connector:

```sh
export E2B_POSTGRES_ENDPOINT=$(tofu -chdir=iac/provider-aws \
  output -raw postgres_endpoint)

dscacheutil -q host -a name "$E2B_POSTGRES_ENDPOINT"
nc -vz "$E2B_POSTGRES_ENDPOINT" 5432
```

The hostname should appear as a synthetic Twingate address and the TCP check should succeed. The
seeder obtains credentials from Secrets Manager; do not put the RDS password in the shell manually.

```sh
E2B_SEED_TEAM_NAME="Tennr staging" \
E2B_SEED_TEAM_SLUG="tennr-staging" \
make seed-db

E2B_SEED_TEAM_NAME="Tennr production" \
E2B_SEED_TEAM_SLUG="tennr-production" \
make seed-db
```

Each command prompts for an email and prints a team ID and one raw API key. Store each raw key
immediately; it cannot be recovered later. The seed command is destructive when rerun for the same
email, so it is a bootstrap tool rather than a rotation mechanism.

Build the `base` template once for each team using that team's bootstrap key:

```sh
read -s "E2B_API_KEY?Team API key: "
echo
export E2B_API_KEY
make -C packages/shared build-base-template
unset E2B_API_KEY
```

## 11. Issue and rotate service API keys

E2B API keys have team-wide authority. They do not have role or scope fields. Isolation comes from
using a different team for staging and production, then issuing a separate named key per workload
inside each team.

Retrieve the cluster admin token without committing it:

```sh
ADMIN_TOKEN=$(aws secretsmanager get-secret-value \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --secret-id "${PREFIX}admin-token" \
  --query SecretString \
  --output text)
```

Create a key for a known team ID:

```sh
curl --fail-with-body --silent --show-error \
  -X POST "https://api.${DOMAIN_NAME}/admin/teams/${TEAM_ID}/api-keys" \
  -H "X-Admin-Token: ${ADMIN_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"name":"workflow-service-2026-08"}'
```

The response contains the raw key exactly once and its stable key ID. Put the raw key in the
correct account's secret manager. Do not share a key between staging and production or between
unrelated services.

To rotate safely:

1. Create a second named key for the same team.
2. Update one consumer at a time and verify its E2B calls.
3. List metadata with `GET /api-keys` using `X-Admin-Token` and `X-Team-ID`; confirm the new key's
   `lastUsed` value advances.
4. Delete the old key by ID only after every consumer has moved:

```sh
curl --fail-with-body --silent --show-error \
  -X DELETE "https://api.${DOMAIN_NAME}/admin/teams/${TEAM_ID}/api-keys/${OLD_KEY_ID}" \
  -H "X-Admin-Token: ${ADMIN_TOKEN}"
```

Unset `ADMIN_TOKEN` when finished. Rotation is create/swap/delete; an existing raw key cannot be
read or changed in place.

## 12. Acceptance and sandbox egress

For each team, run the smoke test with its own key:

```sh
export E2B_DOMAIN="${DOMAIN_NAME}"
read -s "E2B_API_KEY?Team API key: "
echo
export E2B_API_KEY
make -C tests test
e2b sandbox list
unset E2B_API_KEY
```

Private ingress does not restrict sandbox egress. If `allowOut` is omitted, sandboxes may reach the
public internet through NAT. Centralize sandbox creation in Tennr code and send the approved domain
allowlist on every request. An internal destination additionally requires a narrow
`ALLOW_SANDBOX_INTERNAL_CIDRS` exception and a network path. Never exempt an entire Tennr or E2B VPC.

## 13. Updating the fork and cluster

Keep Tennr's commit as one commit directly on top of upstream. To ingest an upstream release:

1. fetch upstream;
2. rebase the single Tennr commit onto the reviewed upstream SHA;
3. run the OpenTofu tests and local validation;
4. rebuild and publish changed artifacts; and
5. plan and apply the shared environment.

Because the custom delta is one commit, conflicts are limited to the maintained AWS integration
rather than a long merge history.

### Applying the large-template capacity update to an existing cluster

Publish the API/db-migrator and template-manager binaries first:

```sh
AUTO_CONFIRM_DEPLOY=true make build-and-upload/api
AUTO_CONFIRM_DEPLOY=true make build-and-upload/template-manager
```

Update the build launch template to `m8i.4xlarge` with an infrastructure-only plan:

```sh
make plan-without-jobs TF=tofu
tofu -chdir=iac/provider-aws show .tfplan.shared
AUTO_CONFIRM_DEPLOY=true make apply TF=tofu
```

Changing an Auto Scaling launch-template version does not replace an already-running instance.
Start a rolling refresh for the build pool and wait for the replacement node to become healthy:

```sh
export BUILD_ASG_NAME="${PREFIX}orch-build"
export BUILD_INSTANCE_REFRESH_ID=$(aws autoscaling start-instance-refresh \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --auto-scaling-group-name "$BUILD_ASG_NAME" \
  --preferences '{"MinHealthyPercentage":0,"InstanceWarmup":180}' \
  --query InstanceRefreshId \
  --output text)

while true; do
  refresh_status=$(aws autoscaling describe-instance-refreshes \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --auto-scaling-group-name "$BUILD_ASG_NAME" \
    --instance-refresh-ids "$BUILD_INSTANCE_REFRESH_ID" \
    --query 'InstanceRefreshes[0].Status' \
    --output text)
  printf 'Build instance refresh: %s\n' "$refresh_status"
  case "$refresh_status" in
    Successful) break ;;
    Failed|Cancelled|RollbackFailed) exit 1 ;;
  esac
  sleep 15
done

nomad node status -json | jq '.[] | select(.NodePool == "build") | {Name,Status,NodePool}'
```

Deploy the new jobs. The API allocation's `db-migrator` applies the capacity migration before API
starts serving new build registrations:

```sh
make plan-only-jobs TF=tofu
tofu -chdir=iac/provider-aws show .tfplan.shared
AUTO_CONFIRM_DEPLOY=true make apply TF=tofu

nomad alloc logs -job api db-migrator
nomad job status api
nomad job status template-manager
```

Confirm the values the API actually reads from `team_limits`, including whether they came through
an explicit project override. This checks database state rather than OpenTofu inputs or tier
defaults:

```sh
AWS_PROFILE="$AWS_PROFILE" \
AWS_REGION="$AWS_REGION" \
POSTGRES_CONNECTION_STRING_SECRET_NAME="${PREFIX}postgres-connection-string" \
./scripts/with-aws-postgres.sh sh -c \
  'psql "$POSTGRES_CONNECTION_STRING" -P pager=off -c "
    SELECT teams.id,
           teams.name,
           limits.max_ram_mb,
           limits.default_free_disk_size_mb,
           limits.max_disk_size_mb,
           (project.team_id IS NOT NULL) AS has_project_override
    FROM public.teams AS teams
    JOIN public.team_limits AS limits ON limits.id = teams.id
    LEFT JOIN public.project_limits AS project ON project.team_id = teams.id
    ORDER BY teams.name;
  "'
```

New build records must show the requested 16 GiB RAM and effective 15 GiB free-rootfs allowance:

```sh
AWS_PROFILE="$AWS_PROFILE" \
AWS_REGION="$AWS_REGION" \
POSTGRES_CONNECTION_STRING_SECRET_NAME="${PREFIX}postgres-connection-string" \
./scripts/with-aws-postgres.sh sh -c \
  'psql "$POSTGRES_CONNECTION_STRING" -P pager=off -c "
    SELECT id, status, ram_mb, free_disk_size_mb, total_disk_size_mb, reason
    FROM public.env_builds
    ORDER BY created_at DESC
    LIMIT 5;
  "'
```

During COPY, the build log contains `copy-space-before`, `copy-space-after-extract`, and
`copy-space-after-cleanup` entries. Their `df -Pk / /tmp` output must show the layer consuming `/`
while `/tmp` remains separate. Rerun the Tot publisher with `memoryMB: 16384` and confirm
`COPY offline-store /opt/tennr/offline-store` advances without HTTP 507.

## 14. Destruction

This shared cluster carries production state. Destruction is intentionally blocked while ALB or RDS
deletion protection is enabled. Before an approved teardown, stop consumers, preserve required S3
and database data, set the protection variables to false, apply that reviewed change, and then run:

```sh
make -C iac/provider-aws destroy TF=tofu
```

KMS keys enter their configured deletion waiting period; they are not immediately erased. Consumer
interface endpoints and private DNS zones live in the staging and production accounts and must be
removed from their own AWS IaC projects separately. The manually deployed E2B Twingate Connector,
its ECS resources, and its security group are also outside the current `e2b-infra` state and require
separate removal.

## External references

- [AWS: Route traffic to an interface endpoint using a Route53 alias](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-to-vpc-interface-endpoint.html)
- [AWS provider: `aws_vpc_endpoint`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint)
- [Twingate: Deploy a Connector on AWS](https://www.twingate.com/docs/aws)
- [Twingate: Resource addresses, wildcard DNS, and port restrictions](https://www.twingate.com/docs/resources)
- [Nomad: Read task logs by job ID](https://developer.hashicorp.com/nomad/commands/alloc/logs)
