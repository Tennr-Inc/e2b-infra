# Private AWS production deployment

This runbook promotes the private AWS staging design into a separate production account and VPC.
It also records every staging bootstrap issue that should not be rediscovered during production.
Nothing here makes the E2B load balancer public: ACM validation uses public DNS only to prove
control of the hostname, while API, Nomad, and sandbox records remain in private Route53.

## What staging taught us

| Staging issue | Durable production behavior |
|---|---|
| `cache.t2.small` is unavailable | Managed Valkey defaults to `cache.t4g.small`. |
| Client proxy received a `rediss://` URI as a socket address | OpenTofu passes `host:6379` and enables TLS separately. |
| AWS clients lacked `orchestrator_job_version` metadata | AWS disables the version constraint and replaces a stable environment-named Nomad system job. |
| The Nomad provider changed an orchestrator update during apply | AWS uses a deterministic orchestrator job ID, so saved plans remain stable. |
| ALB traffic from Twingate timed out | `INGRESS_ALLOWED_SECURITY_GROUP_IDS` manages connector access to HTTPS. |
| RDS administration required a manual security-group rule | `POSTGRES_ADMIN_INGRESS_SECURITY_GROUP_IDS` manages private connector access to port 5432. |
| Historical migrations expected a role named `postgres` | The db migrator creates a no-login compatibility role when it is absent. |
| Local seeding silently tried a Unix socket | AWS `make prep-cluster` and `make seed-db` load the generated connection string from Secrets Manager. |
| The template build printed `Done` after a `BuildError` | The build script now exits nonzero on failure. |
| The smoke test used SDK 0.13 and envd port 49982 | The test uses the current SDK, validates a file round trip, and terminates its sandbox. |
| The smoke-test recipe printed the team API key | The recipe is silent and does not echo the secret-bearing command. |

## Production configuration

Create an ignored environment file from the shared AWS template:

```sh
cp .env.aws.template .env.prod
make set-env ENV=prod
```

Replace every account-, VPC-, subnet-, route-table-, domain-, and security-group value. Do not copy
staging ARNs or IDs. Recommended production differences include:

```sh
PREFIX=e2b-prod-
TERRAFORM_ENVIRONMENT=prod
DOMAIN_NAME=e2b.prod.internal.tennr.com

ENABLE_ALB_DELETION_PROTECTION=true
POSTGRES_MULTI_AZ=true
POSTGRES_DELETION_PROTECTION=true
POSTGRES_SKIP_FINAL_SNAPSHOT=false
POSTGRES_BACKUP_RETENTION_PERIOD=7
```

For HTTPS, either provide an issued wildcard certificate in `INGRESS_CERTIFICATE_ARN`, or leave it
empty. If the authoritative **public** Route53 zone is in the production account, set
`INGRESS_CERTIFICATE_VALIDATION_ZONE_ID`; OpenTofu then creates and retains the ACM validation
CNAME. If DNS is external, leave the zone ID empty and publish the record printed by
`make request-certificate` manually.

Ingress can be security-group-only:

```sh
INGRESS_ALLOWED_CIDR_BLOCKS='[]'
INGRESS_ALLOWED_SECURITY_GROUP_IDS='["sg-connector"]'
```

At least one private CIDR or security group is required, and `0.0.0.0/0` is rejected. Prefer the
Twingate connector security group over an entire subnet. Once the production connector exists in
the E2B VPC, also set:

```sh
POSTGRES_ADMIN_INGRESS_SECURITY_GROUP_IDS='["sg-connector"]'
```

That database rule is for operator bootstrap only. Restrict the corresponding Twingate resource to
the infrastructure administration group.

## Account and operator prerequisites

The selected AWS profile must resolve to `AWS_ACCOUNT_ID`. Authenticate before planning:

```sh
aws sso login --profile <production-profile>
```

OpenTofu creates and passes IAM roles for Nomad node pools. The operator therefore needs the
corresponding IAM role lifecycle and `iam:PassRole` permissions. An explicit deny from an identity
policy, permission boundary, or organization policy cannot be repaired by OpenTofu; use the
approved production infrastructure role before the first apply.

Run the preflight from `main`. Non-development deployment confirmation intentionally refuses feature
branches and asks you to type `production`:

```sh
make aws-private-preflight
```

## Deployment sequence

Initialize the backend and shared bootstrap resources:

```sh
make init
```

If OpenTofu manages the certificate, request it now:

```sh
make request-certificate
```

With `INGRESS_CERTIFICATE_VALIDATION_ZONE_ID` set, that command creates the public validation CNAME
and waits for ACM. Without it, publish the printed CNAME in the authoritative public DNS zone and
check it with `dig` before continuing.

Build and mirror artifacts:

```sh
make provider-login
make -C iac/provider-aws/nomad-cluster-disk-image init
make -C iac/provider-aws/nomad-cluster-disk-image build
make build-and-upload
make copy-public-builds
```

Create the network, RDS, Valkey, Nomad nodes, and private load balancer before scheduling jobs:

```sh
make plan-without-jobs
make apply
```

If the Twingate connector depends on this new VPC, deploy it now. Add its security group to the two
ingress variables, then regenerate and apply the infrastructure plan before deploying jobs.

Create these Twingate resources using the connector in the E2B VPC:

| Resource | Port | Access |
|---|---:|---|
| `*.${DOMAIN_NAME}` | TCP 443 | Developers/operators that use E2B |
| RDS endpoint from `tofu -chdir=iac/provider-aws output -raw postgres_endpoint` | TCP 5432 | Infrastructure administrators only |

The wildcard covers API, Nomad, and dynamic sandbox hostnames. Port 49983 is encoded into sandbox
hostnames; clients still connect to the ALB on 443.

Deploy jobs and automatic database migrations with a newly generated plan:

```sh
make plan
make apply
```

Initialize the first team and base template. On AWS this target reads
`{PREFIX}postgres-connection-string` from Secrets Manager without printing it:

```sh
make prep-cluster
```

Store the emitted team API key in the production secret manager and rotate any key exposed in a
terminal transcript. Then run the end-to-end test:

```sh
read -s "E2B_API_KEY?Team API key: "
echo
export E2B_API_KEY
make -C tests test
unset E2B_API_KEY
```

The test creates a sandbox, writes and reads `/hello.txt`, and kills the sandbox.

## Still intentionally external

- AWS SSO authentication and permission-boundary/SCP changes remain account-administration tasks.
- Twingate connector deployment, resource definitions, and access-group assignments remain in the
  private-access configuration, not this repository.
- External DNS providers still require the ACM validation CNAME when a public Route53 zone is not
  supplied.
- Sandbox egress domains remain a per-create SDK policy. Internal destinations additionally require
  a narrowly scoped `ALLOW_SANDBOX_INTERNAL_CIDRS` value and a route; never allow the full peer VPC.
- Populate `{PREFIX}grafana` and build dashboards for sandbox count, startup latency, failures, and
  node capacity before production traffic. Nomad shows service health, not individual Firecracker
  sandboxes.
