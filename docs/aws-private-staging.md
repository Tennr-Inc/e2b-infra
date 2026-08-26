# Private AWS staging runbook

This runbook deploys E2B into a dedicated AWS VPC and exposes it only to an existing private VPC
over same-account, same-region VPC peering. It does not create a public load balancer, public E2B
routing record, Cloudflare Tunnel, or inbound route from the internet. It may create the public
ACM ownership-validation CNAME when an authoritative Route53 zone is supplied.

For promotion into a separate production account, including the staging workarounds that are now
automated, see [Private AWS production deployment](aws-private-production.md).

## Resulting boundary

- The E2B VPC contains private Nomad nodes, isolated PostgreSQL/Valkey subnets, one NAT gateway,
  AWS endpoints, and an internal Application Load Balancer.
- The peer VPC receives an explicit route to the E2B CIDR. E2B private route tables receive the
  reverse route, and the E2B Route53 private zone is associated with both VPCs.
- The ALB security group accepts HTTPS only from `INGRESS_ALLOWED_CIDR_BLOCKS` and
  `INGRESS_ALLOWED_SECURITY_GROUP_IDS`. Start with the peer VPC CIDR; use a security-group ID for
  Twingate or another connector in the E2B VPC instead of permitting the entire connector subnet.
- VPC peering is not transitive. A VPN or transit-gateway attachment to the peer VPC does not, by
  itself, provide operator access through the peer. Use EC2 Instance Connect/SSM initially, or add
  a direct VPN/Twingate/transit-gateway path later.
- E2B hosts and sandboxes use the NAT gateway for public egress. Private ingress does not change
  outbound behavior.

## Configure

Create an ignored staging environment file:

```sh
cp .env.aws.template .env.staging
make set-env ENV=staging
```

Use a dedicated, non-overlapping VPC CIDR. Supply three availability zones, three NAT/public
subnets, at least three private workload subnets, and three isolated data subnets. Enable managed
Valkey and keep `ALLOW_SANDBOX_INTERNAL_CIDRS` empty for the initial deployment.

Run the read-only checks before creating anything:

```sh
make aws-private-preflight
```

The check verifies the AWS account, peer VPC CIDR and route-table ownership, private ingress list,
required local tools, chosen nested-virtualization instance offerings, and an existing certificate
when one is supplied.

## Bootstrap state, network prerequisites, and ACM

```sh
make init
make request-certificate
```

`make init` creates the encrypted, versioned Terraform state bucket and the initialization module
(VPC, endpoints, artifact buckets, ECR repositories, and secret containers). When
`INGRESS_CERTIFICATE_ARN` is empty, `make request-certificate` creates an ACM certificate request
and prints its DNS validation CNAME. If `INGRESS_CERTIFICATE_VALIDATION_ZONE_ID` identifies the
authoritative public Route53 zone, OpenTofu also publishes the CNAME and waits for ACM to issue the
certificate.

When DNS is external, publish that single CNAME in the public authoritative DNS provider. It proves
domain ownership to ACM; it does not resolve an E2B service or expose the internal ALB. Keep the
validation CNAME so ACM can renew the certificate. Re-run `make certificate-validation-records` if
needed, and wait until ACM reports `ISSUED` before the full apply.

If an issued wildcard certificate already exists, set `INGRESS_CERTIFICATE_ARN` and skip these two
certificate commands. When the authoritative public DNS zone is Route53, set
`INGRESS_CERTIFICATE_VALIDATION_ZONE_ID` and OpenTofu will publish the validation record instead.

## Build and deploy

Build the common Nomad AMI, mirror the public Firecracker artifacts, and build the service images:

```sh
make provider-login
make -C iac/provider-aws/nomad-cluster-disk-image init
make -C iac/provider-aws/nomad-cluster-disk-image build
make build-and-upload
make copy-public-builds
```

Review and apply infrastructure before scheduling jobs:

```sh
make plan-without-jobs
make apply
make plan
make apply
```

The first apply creates the peering routes, private ALB/DNS, encrypted RDS PostgreSQL, managed
Valkey, Nomad node pools, and supporting resources. The second applies the Nomad jobs and database
migrations.

Finally initialize tenant data and a base template:

```sh
make prep-cluster
```

On AWS this retrieves the generated private RDS connection string from Secrets Manager. Your local
machine must be able to reach the RDS endpoint, for example through an administrator-only Twingate
resource whose connector security group is listed in
`POSTGRES_ADMIN_INGRESS_SECURITY_GROUP_IDS`.

## Sandbox egress policy

`ALLOW_SANDBOX_INTERNAL_CIDRS` and the sandbox API/SDK network configuration are separate gates:

1. The infrastructure variable exempts only the listed CIDRs from E2B's built-in private-range
   deny list. It is fleet-wide, so use narrow CIDRs dedicated to authenticated internal gateways;
   never use the full peer VPC CIDR.
2. Every sandbox creation request supplies the domains that workload may reach. If `allowOut` is
   omitted, public internet egress is allowed by default. A template does not impose a durable
   create-time allowlist.

For the JavaScript SDK, centralize sandbox creation in a Tennr-owned wrapper and always set the
allowlist:

```ts
const sandbox = await Sandbox.create(templateId, {
  domain: process.env.E2B_DOMAIN,
  network: {
    allowOut: [
      "api.openai.com",
      "*.github.com",
      "sandbox-gateway.staging.internal.example.com",
    ],
  },
})
```

An internal domain also needs its resolved address covered by `ALLOW_SANDBOX_INTERNAL_CIDRS` and a
route from the E2B private subnets. Keep authentication on that internal gateway; the CIDR exception
applies to every sandbox node. Do not distribute an unrestricted E2B API key to callers that could
bypass the Tennr wrapper. If untrusted callers need direct API access, enforce the domain policy at
a centralized egress proxy or network firewall instead of relying only on SDK options.

## Smoke checks

From a workload in the peer VPC, verify private DNS and HTTPS:

```sh
dig +short api.${DOMAIN_NAME}
curl --fail --silent --show-error https://api.${DOMAIN_NAME}/health
```

Then create a sandbox with the wrapper allowlist and verify one allowed domain succeeds, an omitted
public domain fails, an RFC1918 address fails, and only the explicitly approved internal gateway
succeeds. Also verify that the E2B ALB has `Scheme=internal` and that no public Route53 zone contains
the E2B wildcard.
