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
