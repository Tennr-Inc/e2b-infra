# Private AWS production deployment

This is the end-to-end runbook for deploying Tennr's self-hosted E2B installation into a dedicated
VPC in the production AWS account. It assumes the staging deployment has already been exercised and
that the production E2B VPC will use same-account, same-region VPC peering to reach Tennr's existing
production VPC.

The resulting API, Nomad UI, and sandbox hostnames are private. They are reachable only through the
configured VPC path and private-access connector. The only public DNS record involved is the ACM
ownership-validation CNAME; it does not route application traffic.

## Final topology

- A dedicated E2B VPC spans three availability zones.
- Public subnets contain the NAT gateway used for outbound traffic. E2B nodes do not receive public
  IP addresses.
- Private workload subnets contain Nomad server, API, build, ClickHouse, and Firecracker client
  nodes, plus the Twingate connector when it is deployed in this VPC.
- Isolated data subnets contain private RDS PostgreSQL and managed Valkey.
- An internal Application Load Balancer terminates HTTPS for the API, Nomad, and sandbox wildcard.
- A Route53 private hosted zone contains the service and wildcard records.
- VPC peering provides explicit routes between E2B and the existing production VPC. Peering is not
  transitive.
- Sandbox public egress uses NAT. RFC1918/private destinations remain blocked unless a narrow CIDR
  is explicitly exempted.

## Phase 0: land the deployment code

Production confirmation refuses to run from a feature branch. Merge the E2B Graphite stack, then
start from an up-to-date, clean `main` branch:

```sh
git switch main
git pull --ff-only origin main
git status --short
```

`git status --short` should print nothing. Do not deploy production from one of the draft stack
branches.

## Phase 1: prepare the operator and account

Install these tools locally:

- OpenTofu
- AWS CLI v2
- `jq`
- Packer
- Docker
- Go
- Node.js/npm
- GNU Make

Confirm Docker is running and each command is available:

```sh
command -v tofu aws jq packer docker go npm make
docker info >/dev/null
```

Use a production infrastructure role that can create and pass IAM roles and manage EC2, VPC,
Route53, ACM, RDS, ElastiCache, ECR, S3, Secrets Manager, Auto Scaling, and load-balancing resources.
An explicit IAM, permission-boundary, or organization-policy deny cannot be fixed by OpenTofu.

Authenticate and verify the account before putting its number into configuration:

```sh
PROD_PROFILE=Production-infra
aws sso login --profile "$PROD_PROFILE"
aws sts get-caller-identity --profile "$PROD_PROFILE"
```

Check EC2 quota and regional capacity before deployment. The default initial node pools are:

| Pool | Default capacity |
|---|---|
| Nomad/Consul control servers | 3 × `t3.medium` |
| API | 1 × `t3.xlarge` |
| ClickHouse | 1 × `t3.xlarge` |
| Firecracker clients | 1 × `m8i.4xlarge` |
| Template builds | 1 × `m8i.2xlarge` |

Packer also launches a temporary `t3.large`. Production may need quota increases and additional API
or Firecracker nodes. The preflight verifies that the two nested-virtualization instance types are
offered in the selected region, but AWS quota and capacity still need to be checked separately.

## Phase 2: choose the network layout

First list the production VPCs and their CIDRs:

```sh
aws ec2 describe-vpcs \
  --profile "$PROD_PROFILE" \
  --region us-east-1 \
  --query 'Vpcs[].{Name:Tags[?Key==`Name`]|[0].Value,VpcId:VpcId,Cidr:CidrBlock}' \
  --output table
```

Choose an unused `/16` for E2B. It must not overlap the production VPC, VPN client ranges, any
transit-connected network, or a future peering target. The following is only an example:

```text
E2B VPC:             10.40.0.0/16
NAT/public subnets:  10.40.0.0/24, 10.40.1.0/24, 10.40.2.0/24
private workloads:   10.40.10.0/24, 10.40.11.0/24, 10.40.12.0/24
isolated data:       10.40.20.0/24, 10.40.21.0/24, 10.40.22.0/24
```

The word `public` means those subnets route to an internet gateway so the NAT gateway can work. It
does not mean the E2B services or instances are public.

Identify the existing production VPC to peer and the route tables that need a return route to E2B:

```sh
PROD_VPC_ID=vpc-REPLACE_ME
aws ec2 describe-route-tables \
  --profile "$PROD_PROFILE" \
  --region us-east-1 \
  --filters "Name=vpc-id,Values=$PROD_VPC_ID" \
  --query 'RouteTables[].{RouteTableId:RouteTableId,Name:Tags[?Key==`Name`]|[0].Value,Associations:Associations[].SubnetId}' \
  --output json
```

Include every production route table whose subnets must initiate connections into E2B. Do not copy
the staging VPC or route-table IDs. The current peering configuration expects both VPCs in the same
AWS account and region.

## Phase 3: create `.env.prod`

The environment file is ignored by Git. Create it from the AWS template and select it:

```sh
cp .env.aws.template .env.prod
make set-env ENV=prod
```

`make set-env` selects the file for Make; it does not export its values into the current terminal.
Source it when running the standalone AWS, OpenTofu, Nomad, and E2B CLI commands in this runbook:

```sh
set -a
. ./.env.prod
set +a
PROD_PROFILE=$AWS_PROFILE
```

Populate it with production values. This example shows the important fields; replace every
placeholder and example CIDR:

```sh
PROVIDER=aws
AWS_PROFILE=Production-infra
AWS_ACCOUNT_ID=REPLACE_WITH_PRODUCTION_ACCOUNT_ID
AWS_REGION=us-east-1

PREFIX=e2b-prod-
TERRAFORM_ENVIRONMENT=prod
DOMAIN_NAME=e2b.prod.internal.tennr.com

# Choose one certificate path in Phase 7.
INGRESS_CERTIFICATE_ARN=
INGRESS_CERTIFICATE_VALIDATION_ZONE_ID=Z_REPLACE_WITH_PUBLIC_ZONE_ID

# A private CIDR is acceptable for initial bootstrap. Replace it with the
# connector security group before the full infrastructure plan.
INGRESS_ALLOWED_CIDR_BLOCKS='["REPLACE_WITH_PROD_VPC_CIDR"]'
INGRESS_ALLOWED_SECURITY_GROUP_IDS='[]'

VPC_CIDR=10.40.0.0/16
VPC_AVAILABILITY_ZONES='["us-east-1a","us-east-1b","us-east-1c"]'
VPC_PUBLIC_SUBNETS='["10.40.0.0/24","10.40.1.0/24","10.40.2.0/24"]'
VPC_PRIVATE_SUBNETS='["10.40.10.0/24","10.40.11.0/24","10.40.12.0/24"]'
VPC_ELASTICACHE_SUBNETS='["10.40.20.0/24","10.40.21.0/24","10.40.22.0/24"]'

PEER_VPC_ID=vpc-REPLACE_ME
PEER_VPC_CIDR=REPLACE_WITH_PROD_VPC_CIDR
PEER_ROUTE_TABLE_IDS='["rtb-REPLACE_1","rtb-REPLACE_2","rtb-REPLACE_3"]'

ENABLE_ALB_DELETION_PROTECTION=true
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

# Keep private access blocked for the first production deployment.
ALLOW_SANDBOX_INTERNAL_CIDRS=
```

For higher availability, consider starting with two API nodes, ingress instances, and client
proxies:

```sh
API_CLUSTER_SIZE=2
INGRESS_COUNT=2
CLIENT_PROXY_COUNT=2
```

Size `CLIENT_CLUSTER_SIZE` from expected concurrent sandbox load and leave capacity headroom. Keep
`BUILD_CLUSTER_SIZE` at one initially unless simultaneous template builds are required.

The default backend bucket is `${AWS_ACCOUNT_ID}-terraform-state`, with state key
`terraform/orchestration/state`. Because staging and production use separate AWS accounts, their
state remains separate. Do not point production at the staging bucket.

## Phase 4: run read-only checks

Refresh SSO if necessary and verify the selected environment and account:

```sh
aws sso login --profile "$PROD_PROFILE"
make -C iac/provider-aws verify-account
make aws-private-preflight
```

The preflight checks:

- local tools;
- AWS account identity;
- JSON array syntax;
- the VPC and route-table relationship;
- private ingress configuration;
- connector security-group syntax;
- nested-virtualization instance offerings;
- the ACM certificate, when an existing ARN is supplied; and
- that the optional certificate-validation zone is public and authoritative for `DOMAIN_NAME`.

Stop here if anything is wrong. In particular, do not work around an account mismatch or IAM
explicit deny.

## Phase 5: initialize state and bootstrap resources

Run:

```sh
make init
```

For production, the confirmation script asks you to type `production`. This command is more than a
normal `tofu init`: it creates or secures the S3 state bucket, initializes the backend, and applies
`module.init`. That bootstrap module creates the VPC, subnets, NAT path, VPC endpoints, artifact
buckets, ECR repositories, and secret containers.

Record the new VPC and private workload subnets:

```sh
tofu -chdir=iac/provider-aws output -raw vpc_id
tofu -chdir=iac/provider-aws output -json vpc_private_subnet_ids
```

At this point there is no public E2B ingress and the full Nomad cluster has not been deployed.

## Phase 6: deploy the production Twingate connector

Deploy a dedicated production connector into at least one of the E2B private workload subnets from
Phase 5. For production availability, use two connectors in different availability zones when the
Twingate deployment supports it. Attach the same purpose-built connector security group to both.

The connector security group is the value OpenTofu needs—not the subnet ID and not the synthetic
`100.x.x.x` address that Twingate returns on laptops. The connector normally needs no broad inbound
rule; its egress must permit the Twingate control plane, DNS, HTTPS to the internal ALB, and
PostgreSQL to RDS.

After the connector is healthy, replace the bootstrap CIDR access in `.env.prod`:

```sh
INGRESS_ALLOWED_CIDR_BLOCKS='[]'
INGRESS_ALLOWED_SECURITY_GROUP_IDS='["sg-REPLACE_WITH_CONNECTOR_SG"]'
POSTGRES_ADMIN_INGRESS_SECURITY_GROUP_IDS='["sg-REPLACE_WITH_CONNECTOR_SG"]'
```

Run the preflight again:

```sh
make aws-private-preflight
```

OpenTofu will use the connector security group as the source for ALB port 443 and RDS port 5432.
It does not grant the connector access to Valkey.

## Phase 7: obtain the wildcard certificate

The certificate must be in `AWS_REGION` and cover `*.${DOMAIN_NAME}`. Choose exactly one path.

### Path A: reuse an issued ACM certificate

Set `INGRESS_CERTIFICATE_ARN` and leave `INGRESS_CERTIFICATE_VALIDATION_ZONE_ID` empty. Verify it:

```sh
aws acm describe-certificate \
  --profile "$PROD_PROFILE" \
  --region us-east-1 \
  --certificate-arn "$INGRESS_CERTIFICATE_ARN" \
  --query 'Certificate.{Status:Status,Names:SubjectAlternativeNames}'
```

The status must be `ISSUED` and the names must cover the wildcard.

### Path B: let OpenTofu request and validate it

Leave `INGRESS_CERTIFICATE_ARN` empty. If Route53 hosts authoritative public DNS, set
`INGRESS_CERTIFICATE_VALIDATION_ZONE_ID` to the **public** hosted zone ID. A private zone with the
same name will not work for ACM.

```sh
make request-certificate
```

When the public Route53 zone ID is configured, this creates the CNAME and waits for issuance. The
record proves domain ownership only; it does not point at the ALB.

When authoritative public DNS is external, leave the zone ID empty. The command prints a CNAME;
publish that exact name and value in the public provider, with proxying disabled. Verify public
resolution and ACM status:

```sh
make certificate-validation-records
dig +short CNAME _REPLACE_WITH_VALIDATION_NAME @1.1.1.1
aws acm describe-certificate \
  --profile "$PROD_PROFILE" \
  --region us-east-1 \
  --certificate-arn "$(tofu -chdir=iac/provider-aws output -raw ingress_certificate_arn)" \
  --query 'Certificate.Status' \
  --output text
```

Wait for `ISSUED`. Keep the validation CNAME permanently so ACM can renew the certificate.

## Phase 8: build and publish artifacts

Authenticate Docker to the production ECR registry:

```sh
make provider-login
```

Build the common Nomad AMI:

```sh
make -C iac/provider-aws/nomad-cluster-disk-image init
make -C iac/provider-aws/nomad-cluster-disk-image build
```

Build and upload the E2B components:

```sh
make build-and-upload
```

This invokes nine component targets: API, client proxy, dashboard API, NFS cache cleaner,
orchestrator, template manager, envd, ClickHouse migrator, and Nomad node-pool APM.

Copy the public Firecracker kernels, Firecracker versions, and BusyBox artifacts into the
production buckets:

```sh
make copy-public-builds
```

ECR login tokens expire after 12 hours. Re-run `make provider-login` if an upload reports an
authentication error.

## Phase 9: create infrastructure without Nomad jobs

Create a saved infrastructure-only plan:

```sh
make plan-without-jobs
```

Review `.tfplan.prod` before applying it:

```sh
tofu -chdir=iac/provider-aws show .tfplan.prod
```

Confirm at least the following:

- the AWS account, region, and prefixes are production values;
- the ALB has `internal = true`;
- RDS has `publicly_accessible = false`, encryption, Multi-AZ, deletion protection, and a final
  snapshot enabled;
- Valkey has transit/at-rest encryption and Multi-AZ failover;
- HTTPS ingress comes only from the connector security group or explicitly approved private CIDR;
- RDS ingress includes the cluster-node and connector security groups;
- the production peer VPC and return route tables are correct; and
- there are no staging ARNs, VPC IDs, subnet IDs, route tables, or security groups.

If any value changes after planning, discard the saved plan by running `make plan-without-jobs`
again. Apply only the reviewed plan:

```sh
make apply
```

This creates the internal ALB/private DNS, peering and routes, encrypted RDS, managed Valkey, Nomad
nodes, and supporting infrastructure. It does not yet schedule the E2B service jobs.

Capture the endpoints:

```sh
tofu -chdir=iac/provider-aws output -raw private_alb_dns_name
tofu -chdir=iac/provider-aws output -raw postgres_endpoint
tofu -chdir=iac/provider-aws output -raw redis_endpoint
```

## Phase 10: create Twingate resources

Use the connector deployed in the E2B VPC. Create:

| Address | Port | Suggested access |
|---|---:|---|
| `*.${DOMAIN_NAME}` | TCP 443 | Developers and services allowed to use E2B |
| RDS endpoint from the OpenTofu output | TCP 5432 | Infrastructure administrators only |

The wildcard is required because sandbox hostnames are dynamic. It also covers `api` and `nomad`,
so Nomad ACL authentication remains required. If Twingate access policies can give an exact Nomad
resource stricter access than the wildcard, add `nomad.${DOMAIN_NAME}` for the infrastructure group
and verify the overlap behavior in the Tennr Twingate configuration.

The Twingate client will commonly resolve these names to synthetic `100.x.x.x` addresses. That is
expected. The connector, not the laptop, makes the connection to the private AWS endpoint.

Before jobs exist, verify that the path reaches the ALB and completes TLS:

```sh
dscacheutil -q host -a name api.${DOMAIN_NAME}
curl -sv --connect-timeout 10 https://api.${DOMAIN_NAME}/
curl -sv --connect-timeout 10 https://nomad.${DOMAIN_NAME}/
```

An API `502` at this stage is expected because the API job is not running. A TCP timeout or TLS
handshake timeout is not expected; it usually means the connector selection, connector egress, or
ALB security-group source is wrong.

## Phase 11: deploy Nomad jobs and migrations

Generate a new full plan. Do not reuse the targeted infrastructure plan:

```sh
make plan
tofu -chdir=iac/provider-aws show .tfplan.prod
```

Review the Nomad job changes, then apply:

```sh
make apply
```

The API allocation runs database migrations. The migrator creates the no-login `postgres`
compatibility role before applying historical migrations, so no manual RDS query should be needed.

Authenticate to Nomad for job and allocation inspection without printing its ACL token:

```sh
export NOMAD_ADDR="https://nomad.${DOMAIN_NAME}"
export NOMAD_TOKEN="$(aws secretsmanager get-secret-value \
  --profile "$PROD_PROFILE" \
  --region us-east-1 \
  --secret-id "${PREFIX}cluster" \
  --query SecretString \
  --output text | jq -r .NOMAD_ACL_TOKEN)"
nomad job status
nomad ui -authenticate
```

Unset the token when finished:

```sh
unset NOMAD_TOKEN
```

Wait until the API, ingress, client proxy, template manager, ClickHouse, telemetry, and log jobs are
healthy. A failed allocation should be investigated before seeding production.

## Phase 12: seed the first team and build the base template

The laptop must have active Twingate access to the RDS endpoint on port 5432. Run:

```sh
make prep-cluster
```

On AWS, this fetches `${PREFIX}postgres-connection-string` from Secrets Manager without printing
the database password. The seed step prompts for an email and prints a new team ID and team API key.
Immediately store that key in Tennr's production secret manager. The following base-template step
asks for `E2B_API_KEY`; paste the key that was just generated.

**Treat this as a one-time bootstrap operation.** Rerunning the seed with the same email deletes and
recreates that email's team, including its environments, snapshots, volumes, and API key. To rebuild
only the base template later, set the existing team key and run the template target directly:

```sh
read -s "E2B_API_KEY?Team API key: "
echo
export E2B_API_KEY
make -C packages/shared build-base-template
unset E2B_API_KEY
```

Do not save the API key in `.env.prod` or commit it.

## Phase 13: run acceptance checks

Verify private DNS and HTTPS through Twingate:

```sh
curl --fail --silent --show-error https://api.${DOMAIN_NAME}/health
curl -I https://nomad.${DOMAIN_NAME}/
```

Nomad should redirect `/` to `/ui/`, and the API health request should succeed rather than return an
ALB `502`.

Run the end-to-end SDK test with the team key:

```sh
read -s "E2B_API_KEY?Team API key: "
echo
export E2B_API_KEY
make -C tests test
E2B_DOMAIN=${DOMAIN_NAME} e2b sandbox list
unset E2B_API_KEY
```

The test creates a sandbox from the `base` template, writes and reads `/hello.txt`, and terminates
the sandbox. The following list confirms no sandbox was left behind.

Also verify the security boundary:

- the ALB scheme is `internal`;
- RDS and Valkey have no public endpoints;
- no public hosted zone contains an ALB alias or E2B wildcard;
- only the ACM validation CNAME is public;
- HTTPS works with Twingate connected and fails without authorized Twingate access;
- RDS is available only to the infrastructure administration group; and
- `ALLOW_SANDBOX_INTERNAL_CIDRS` is still empty.

## Phase 14: define sandbox egress deliberately

Private ingress does not restrict sandbox egress. If `allowOut` is omitted from sandbox creation,
public internet egress is allowed by default. Centralize sandbox creation in a Tennr-owned wrapper
and supply the approved domain list on every request:

```ts
const sandbox = await Sandbox.create(templateId, {
  domain: process.env.E2B_DOMAIN,
  network: {
    allowOut: [
      "api.openai.com",
      "*.github.com",
      "sandbox-gateway.prod.internal.tennr.com",
    ],
  },
})
```

An internal destination needs three independent controls:

1. its resolved IP is within a narrow `ALLOW_SANDBOX_INTERNAL_CIDRS` exception;
2. E2B private subnets have a route to it; and
3. the sandbox request's `allowOut` includes its domain.

Never set `ALLOW_SANDBOX_INTERNAL_CIDRS` to the full production or peer VPC CIDR. Prefer a dedicated,
authenticated gateway with the smallest practical CIDR. The infrastructure exception is fleet-wide.

## Troubleshooting

| Symptom | Meaning and next check |
|---|---|
| AWS SSO `InvalidGrantException` | The cached session expired. Run `aws sso login --profile "$PROD_PROFILE"`. |
| IAM `explicit deny` | Use the approved production infrastructure role or change the boundary/SCP; OpenTofu cannot override it. |
| ACM remains `PENDING_VALIDATION` | Confirm the CNAME is in authoritative **public** DNS, not the private hosted zone, and query it with `dig ... @1.1.1.1`. |
| Twingate resolves to `100.x.x.x` | Normal client-side synthetic addressing. Continue by checking TCP and TLS. |
| TCP connects but TLS stalls | Check that the ALB security group contains the connector SG and that the selected connector is attached to that SG/VPC. |
| API returns ALB `502` | The private path and certificate work; inspect API/client-proxy target health and Nomad allocation logs. |
| Client proxy reports `rediss://... too many colons` | The deployed job/image predates the managed-Valkey address fix. Rebuild artifacts and apply a fresh full plan from current `main`. |
| Migration reports `role "postgres" does not exist` | The db-migrator image/job predates the compatibility-role fix. Rebuild and redeploy it; do not change the RDS master username. |
| Seed tries `/private/tmp/.s.PGSQL.5432` | The AWS environment was not selected or the wrapper did not receive the secret name. Re-run `make set-env ENV=prod` and use the root `make prep-cluster` target. |
| Sandbox creation times out | Inspect orchestrator/API/client-proxy allocations, Firecracker client node health, ALB target health, and `e2b sandbox list`. |
| OpenTofu reports a Nomad inconsistent final plan | Discard the saved plan and generate a fresh full plan from current `main`; routine targeted applies should not be used. |

## Recovery and rollback

- A plan is safe to abandon. If inputs change, generate a new plan instead of applying the old
  `.tfplan.prod`.
- If infrastructure succeeds but jobs fail, keep the VPC and data services running, inspect Nomad,
  fix or roll back the application revision, and run a new full plan/apply.
- Do not use `make destroy` as a production rollback. RDS deletion protection intentionally blocks
  deletion, and the state, secrets, snapshots, and artifact buckets are durable data.
- Do not change the RDS master username to solve the historical `postgres` role issue; that can
  force database replacement. The migrator compatibility role is the safe fix.
- Use OpenTofu targeting only for documented bootstrap or recovery operations. Normal production
  changes should use a complete saved plan.

## Production completion checklist

- [ ] Deployment stack merged and checked out on clean `main`
- [ ] Production AWS identity and IAM permissions verified
- [ ] Non-overlapping E2B VPC and production peer routes reviewed
- [ ] `.env.prod` contains no staging IDs or ARNs
- [ ] EC2 quota/capacity checked
- [ ] State/bootstrap initialization completed
- [ ] Production Twingate connectors healthy in private subnets
- [ ] Connector SG configured for HTTPS and administrator-only RDS access
- [ ] Wildcard ACM certificate issued
- [ ] Images, AMI, kernels, Firecracker, and BusyBox artifacts published
- [ ] Infrastructure-only plan reviewed and applied
- [ ] Twingate wildcard and RDS resources tested
- [ ] Full Nomad plan reviewed and applied
- [ ] All Nomad jobs healthy
- [ ] First team seeded once and API key stored securely
- [ ] Base template and SDK smoke test succeeded
- [ ] No sandbox left running after the smoke test
- [ ] Sandbox egress allowlist and any internal gateway exception explicitly approved
- [ ] Grafana/observability configured for sandbox count, startup latency, failures, and node capacity

## Staging issues already made durable

| Staging issue | Production behavior |
|---|---|
| `cache.t2.small` was unavailable | Managed Valkey defaults to `cache.t4g.small`. |
| Client proxy received a `rediss://` URI as a socket address | OpenTofu passes `host:6379` and enables TLS separately. |
| AWS clients lacked `orchestrator_job_version` metadata | AWS disables that placement constraint. |
| Nomad provider changed the orchestrator update during apply | AWS uses a deterministic environment-named orchestrator job ID. |
| ALB traffic from Twingate timed out | Connector access is managed by `INGRESS_ALLOWED_SECURITY_GROUP_IDS`. |
| RDS administration needed a manual rule | `POSTGRES_ADMIN_INGRESS_SECURITY_GROUP_IDS` manages port 5432 access. |
| Historical migrations expected the `postgres` role | The migrator creates a no-login compatibility role. |
| Local seeding attempted a Unix socket | AWS bootstrap targets load the managed RDS secret. |
| Template builds printed `Done` after failure | The build script now exits nonzero. |
| Smoke tests used an obsolete SDK and leaked sandboxes | The current test validates a file round trip and always terminates the sandbox. |
| Smoke-test commands printed the team API key | The recipe no longer echoes the secret-bearing command. |
