output "connection_string" {
  value     = local.connection_string
  sensitive = true
}

output "endpoint" {
  value = aws_db_instance.this.endpoint
}

output "security_group_id" {
  value = aws_security_group.this.id
}

output "security_posture" {
  description = "Non-sensitive controls exposed for plans and policy tests"
  value = {
    backup_retention_period = aws_db_instance.this.backup_retention_period
    deletion_protection     = aws_db_instance.this.deletion_protection
    force_ssl               = one([for parameter in aws_db_parameter_group.this.parameter : parameter if parameter.name == "rds.force_ssl"]).value == "1"
    publicly_accessible     = aws_db_instance.this.publicly_accessible
    storage_encrypted       = aws_db_instance.this.storage_encrypted
  }
}
