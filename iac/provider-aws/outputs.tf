output "vpc_id" {
  description = "Dedicated E2B VPC ID"
  value       = module.init.vpc_id
}

output "vpc_private_subnet_ids" {
  description = "Private workload subnets suitable for private-access connectors"
  value       = module.init.vpc_private_subnet_ids
}

output "private_alb_dns_name" {
  description = "AWS-generated DNS name for the internal E2B ALB"
  value       = aws_lb.ingress.dns_name
}

output "private_route53_zone_id" {
  description = "Route53 private hosted zone containing the E2B wildcard record"
  value       = aws_route53_zone.private.zone_id
}

output "privatelink_service_name" {
  description = "Endpoint service name used to create interface endpoints in Tennr consumer accounts"
  value       = aws_vpc_endpoint_service.ingress.service_name
}

output "privatelink_service_id" {
  description = "Provider-side VPC endpoint service ID"
  value       = aws_vpc_endpoint_service.ingress.id
}

output "privatelink_nlb_dns_name" {
  description = "AWS-generated DNS name for the internal PrivateLink NLB"
  value       = aws_lb.privatelink.dns_name
}

output "postgres_endpoint" {
  description = "Private RDS PostgreSQL endpoint"
  value       = module.postgres.endpoint
}

output "postgres_connection_string_secret_name" {
  description = "Secrets Manager secret containing the RDS PostgreSQL connection string"
  value       = module.init.postgres_connection_string_secret_name
}

output "redis_endpoint" {
  description = "Private managed Valkey endpoint, or null when managed Redis is disabled"
  value       = var.redis_managed ? module.redis[0].endpoint_address : null
}

output "ingress_certificate_arn" {
  description = "ACM certificate used by the private HTTPS listener"
  value       = local.ingress_certificate_arn
}

output "certificate_dns_validation_records" {
  description = "Public DNS CNAMEs required only to validate a Terraform-managed ACM certificate"
  value = local.manage_ingress_certificate ? [
    for option in aws_acm_certificate.ingress[0].domain_validation_options : {
      domain = option.domain_name
      name   = option.resource_record_name
      type   = option.resource_record_type
      value  = option.resource_record_value
    }
  ] : []
}

output "ebs_kms_key_arn" {
  description = "Customer-managed KMS key for EBS volumes and AMI snapshots"
  value       = module.init.ebs_kms_key_arn
}

output "rds_kms_key_arn" {
  description = "Customer-managed KMS key for PostgreSQL storage and snapshots"
  value       = module.init.rds_kms_key_arn
}

output "s3_kms_key_arn" {
  description = "Customer-managed KMS key for E2B S3 application data"
  value       = module.init.s3_kms_key_arn
}
