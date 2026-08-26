output "endpoint_address" {
  value = aws_elasticache_replication_group.instance.configuration_endpoint_address
}

output "endpoint_ca_pem_base64" {
  value = local.redis_ca_pem_base64
}

output "security_posture" {
  description = "Non-sensitive controls exposed for plans and policy tests"
  value = {
    at_rest_encryption_enabled = aws_elasticache_replication_group.instance.at_rest_encryption_enabled
    automatic_failover_enabled = aws_elasticache_replication_group.instance.automatic_failover_enabled
    ingress_security_groups    = var.ingress_security_group_ids
    multi_az_enabled           = aws_elasticache_replication_group.instance.multi_az_enabled
    snapshot_retention_limit   = aws_elasticache_replication_group.instance.snapshot_retention_limit
    transit_encryption_enabled = aws_elasticache_replication_group.instance.transit_encryption_enabled
  }
}
