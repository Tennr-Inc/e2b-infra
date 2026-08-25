output "vpc_id" {
  description = "Dedicated E2B VPC ID"
  value       = module.init.vpc_id
}

output "private_alb_dns_name" {
  description = "AWS-generated DNS name for the internal E2B ALB"
  value       = aws_lb.ingress.dns_name
}

output "private_route53_zone_id" {
  description = "Route53 private hosted zone containing the E2B wildcard record"
  value       = aws_route53_zone.private.zone_id
}

output "vpc_peering_connection_id" {
  description = "VPC peering connection ID, or null when peering is disabled"
  value       = local.peering_enabled ? aws_vpc_peering_connection.peer[0].id : null
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
