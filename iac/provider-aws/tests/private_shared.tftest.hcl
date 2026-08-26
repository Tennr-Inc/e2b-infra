mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000001"
      domain_validation_options = [{
        domain_name           = "*.e2b.internal.example.com"
        resource_record_name  = "_validation.e2b.internal.example.com"
        resource_record_type  = "CNAME"
        resource_record_value = "_validation.acm-validations.aws"
      }]
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/e2b-test"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001"
      key_id = "00000000-0000-0000-0000-000000000001"
    }
  }

  mock_resource "aws_launch_template" {
    defaults = {
      id = "lt-0123456789abcdef0"
    }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn      = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/e2b-test/0123456789abcdef"
      dns_name = "internal-e2b-test.us-east-1.elb.amazonaws.com"
    }
  }

  mock_resource "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/e2b-test/0123456789abcdef/0123456789abcdef"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/e2b-test/0123456789abcdef"
    }
  }

  mock_resource "aws_vpc_endpoint_service" {
    defaults = {
      id           = "vpce-svc-0123456789abcdef0"
      service_name = "com.amazonaws.vpce.us-east-1.vpce-svc-0123456789abcdef0"
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

  environment   = "shared"
  prefix        = "e2b-shared-"
  bucket_prefix = "e2b-shared-test-"
  domain_name   = "e2b.internal.example.com"

  ingress_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  privatelink_allowed_principal_arns = [
    "arn:aws:iam::111122223333:root",
    "arn:aws:iam::444455556666:root",
  ]
  postgres_admin_ingress_security_group_ids = [
    "sg-0fedcba9876543210",
  ]

  vpc_cidr                = "10.30.0.0/16"
  vpc_availability_zones  = ["us-east-1a", "us-east-1b", "us-east-1c"]
  vpc_public_subnets      = ["10.30.0.0/24", "10.30.1.0/24", "10.30.2.0/24"]
  vpc_private_subnets     = ["10.30.10.0/24", "10.30.11.0/24", "10.30.12.0/24"]
  vpc_elasticache_subnets = ["10.30.20.0/24", "10.30.21.0/24", "10.30.22.0/24"]
}

run "shared_private_topology" {
  command = plan

  assert {
    condition     = aws_lb.ingress.internal && aws_lb.ingress.load_balancer_type == "application"
    error_message = "The E2B application load balancer must remain internal."
  }

  assert {
    condition     = aws_lb_listener.ingress_wildcard.port == 443 && aws_lb_listener.ingress_wildcard.protocol == "HTTPS"
    error_message = "The E2B ALB must terminate HTTPS only."
  }

  assert {
    condition     = aws_lb.privatelink.internal && aws_lb.privatelink.load_balancer_type == "network"
    error_message = "PrivateLink must use an internal network load balancer."
  }

  assert {
    condition     = aws_lb_target_group.privatelink_alb.target_type == "alb" && aws_lb_target_group.privatelink_alb.port == 443
    error_message = "The PrivateLink NLB must forward TLS to the internal ALB target."
  }

  assert {
    condition     = !aws_vpc_endpoint_service.ingress.acceptance_required && length(aws_vpc_endpoint_service_allowed_principal.consumer) == 2
    error_message = "Only explicitly allowed Tennr account principals may create automatically accepted endpoints."
  }

  assert {
    condition     = aws_route53_zone.private.name == "e2b.internal.example.com" && aws_route53_record.wildcard.name == "*.e2b.internal.example.com"
    error_message = "The provider-side wildcard must remain in a private shared zone."
  }

  assert {
    condition     = var.allow_sandbox_internal_cidrs == ""
    error_message = "The shared fleet must not allow sandbox access to private CIDRs by default."
  }

  assert {
    condition     = module.postgres.security_posture.storage_encrypted && !module.postgres.security_posture.publicly_accessible
    error_message = "PostgreSQL must be encrypted and have no public endpoint."
  }

  assert {
    condition     = module.postgres.security_posture.kms_key_id == module.init.rds_kms_key_arn
    error_message = "PostgreSQL must use the dedicated RDS customer-managed key."
  }

  assert {
    condition = (
      module.init.kms_security_posture.ebs_key_rotation_enabled &&
      module.init.kms_security_posture.rds_key_rotation_enabled &&
      module.init.kms_security_posture.s3_key_rotation_enabled
    )
    error_message = "All E2B customer-managed keys must rotate automatically."
  }

  assert {
    condition     = module.init.kms_security_posture.kms_encrypted_bucket_count == 9
    error_message = "Every E2B application bucket must use the S3 customer-managed key."
  }

  assert {
    condition     = module.init.kms_security_posture.load_balancer_logs_sse_algorithm == "AES256"
    error_message = "ALB access logs must retain the AWS-supported SSE-S3 configuration."
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

  assert {
    condition     = can(regex("^[^:]+:6379$", local.redis_cluster_url)) && local.redis_tls_enabled == "true"
    error_message = "Managed Redis must use a bare host:port address while enabling TLS separately."
  }

  assert {
    condition     = !contains(module.redis[0].security_posture.ingress_security_groups, "sg-0fedcba9876543210")
    error_message = "The database administration connector must not receive Valkey access."
  }
}

run "managed_certificate" {
  command = plan

  variables {
    ingress_certificate_arn = ""
  }

  assert {
    condition     = aws_acm_certificate.ingress[0].domain_name == "*.e2b.internal.example.com" && aws_acm_certificate.ingress[0].validation_method == "DNS"
    error_message = "Terraform-managed ingress certificates must use DNS validation for the private wildcard domain."
  }
}

run "reject_invalid_privatelink_principal" {
  command = plan

  variables {
    privatelink_allowed_principal_arns = ["not-an-arn"]
  }

  expect_failures = [var.privatelink_allowed_principal_arns]
}

run "reject_missing_privatelink_principal" {
  command = plan

  variables {
    privatelink_allowed_principal_arns = []
  }

  expect_failures = [var.privatelink_allowed_principal_arns]
}

run "reject_invalid_postgres_admin_security_group" {
  command = plan

  variables {
    postgres_admin_ingress_security_group_ids = ["not-a-security-group"]
  }

  expect_failures = [var.postgres_admin_ingress_security_group_ids]
}

run "reject_single_node_managed_redis" {
  command = plan

  variables {
    redis_managed      = true
    redis_replica_size = 1
  }

  expect_failures = [var.redis_replica_size]
}
