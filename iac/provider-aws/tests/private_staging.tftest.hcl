mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}
mock_provider "external" {}
mock_provider "http" {}
mock_provider "nomad" {}
mock_provider "random" {}

variables {
  aws_account_id = "123456789012"
  aws_region     = "us-east-1"

  environment   = "staging"
  prefix        = "e2b-stg-"
  bucket_prefix = "e2b-stg-test-"
  domain_name   = "e2b.staging.internal.example.com"

  ingress_certificate_arn     = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  ingress_allowed_cidr_blocks = ["10.20.0.0/16"]

  vpc_cidr                = "10.30.0.0/16"
  vpc_availability_zones  = ["us-east-1a", "us-east-1b", "us-east-1c"]
  vpc_public_subnets      = ["10.30.0.0/24", "10.30.1.0/24", "10.30.2.0/24"]
  vpc_private_subnets     = ["10.30.10.0/24", "10.30.11.0/24", "10.30.12.0/24"]
  vpc_elasticache_subnets = ["10.30.20.0/24", "10.30.21.0/24", "10.30.22.0/24"]

  peer_vpc_id   = "vpc-0123456789abcdef0"
  peer_vpc_cidr = "10.20.0.0/16"
  peer_route_table_ids = [
    "rtb-00000000000000001",
    "rtb-00000000000000002",
    "rtb-00000000000000003",
  ]
}

run "private_staging_topology" {
  command = plan

  assert {
    condition     = aws_lb.ingress.internal
    error_message = "The E2B ALB must remain internal."
  }

  assert {
    condition     = aws_lb_listener.ingress_wildcard.port == 443 && aws_lb_listener.ingress_wildcard.protocol == "HTTPS"
    error_message = "The E2B ALB must expose HTTPS only."
  }

  assert {
    condition     = aws_lb_listener.ingress_wildcard.certificate_arn == var.ingress_certificate_arn
    error_message = "The ALB must use the explicitly supplied staging ACM certificate."
  }

  assert {
    condition     = length(aws_security_group.ingress.ingress) == 1 && alltrue([for rule in aws_security_group.ingress.ingress : rule.from_port == 443 && rule.to_port == 443 && length(rule.cidr_blocks) == 1 && contains(rule.cidr_blocks, "10.20.0.0/16")])
    error_message = "Ingress must be limited to HTTPS from the configured staging CIDR."
  }

  assert {
    condition     = aws_route53_zone.private.name == "e2b.staging.internal.example.com" && aws_route53_record.wildcard.name == "*.e2b.staging.internal.example.com"
    error_message = "The sandbox wildcard must exist only in the private staging zone."
  }

  assert {
    condition     = aws_vpc_peering_connection.peer[0].peer_vpc_id == "vpc-0123456789abcdef0" && length(aws_route.peer_to_e2b) == 3
    error_message = "The E2B VPC must peer with staging and install every configured return route."
  }

  assert {
    condition     = var.allow_sandbox_internal_cidrs == ""
    error_message = "Initial staging must not allow sandbox access to private CIDRs."
  }

  assert {
    condition     = module.postgres.security_posture.storage_encrypted && !module.postgres.security_posture.publicly_accessible
    error_message = "PostgreSQL must be encrypted and have no public endpoint."
  }

  assert {
    condition     = module.postgres.security_posture.deletion_protection && module.postgres.security_posture.backup_retention_period == 7
    error_message = "PostgreSQL must retain backups and resist accidental deletion by default."
  }

  assert {
    condition     = module.postgres.security_posture.force_ssl
    error_message = "PostgreSQL must reject non-TLS client connections."
  }
}

run "managed_redis_topology" {
  command = plan

  variables {
    redis_managed = true
  }

  assert {
    condition     = module.redis[0].security_posture.at_rest_encryption_enabled && module.redis[0].security_posture.transit_encryption_enabled
    error_message = "Managed Redis must encrypt data at rest and in transit."
  }

  assert {
    condition     = module.redis[0].security_posture.multi_az_enabled && module.redis[0].security_posture.automatic_failover_enabled
    error_message = "Managed Redis must use Multi-AZ automatic failover."
  }
}

run "managed_certificate" {
  command = plan

  variables {
    ingress_certificate_arn = ""
  }

  assert {
    condition     = aws_acm_certificate.ingress[0].domain_name == "*.e2b.staging.internal.example.com" && aws_acm_certificate.ingress[0].validation_method == "DNS"
    error_message = "Terraform-managed ingress certificates must use DNS validation for the private wildcard domain."
  }
}

run "reject_public_ingress" {
  command = plan

  variables {
    ingress_allowed_cidr_blocks = ["0.0.0.0/0"]
  }

  expect_failures = [var.ingress_allowed_cidr_blocks]
}

run "reject_incomplete_peering" {
  command = plan

  variables {
    peer_route_table_ids = []
  }

  expect_failures = [aws_vpc_peering_connection.peer[0]]
}

run "reject_single_node_managed_redis" {
  command = plan

  variables {
    redis_managed      = true
    redis_replica_size = 1
  }

  expect_failures = [var.redis_replica_size]
}
