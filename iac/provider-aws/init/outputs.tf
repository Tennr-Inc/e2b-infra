// ---
// Buckets
// ---
output "setup_bucket_name" {
  value = aws_s3_bucket.setup.bucket
}

output "fc_template_build_cache_bucket_name" {
  value = aws_s3_bucket.fc_template_build_cache.bucket
}

output "fc_template_bucket_name" {
  value = aws_s3_bucket.fc_templates.bucket
}

output "fc_env_pipeline_bucket_name" {
  value = aws_s3_bucket.fc_env_pipeline.bucket
}

output "fc_kernels_bucket_name" {
  value = aws_s3_bucket.fc_kernels.bucket
}

output "fc_versions_bucket_name" {
  value = aws_s3_bucket.fc_versions.bucket
}

output "fc_busybox_bucket_name" {
  value = aws_s3_bucket.fc_busybox.bucket
}

output "load_balancer_logs_bucket_name" {
  value = aws_s3_bucket.load_balancer_logs.bucket
}

output "loki_bucket_name" {
  value = aws_s3_bucket.loki_storage.bucket
}

output "clickhouse_backups_bucket_name" {
  value = aws_s3_bucket.clickhouse_backups.bucket
}

// ---
// ECR Repositories
// ---
output "client_proxy_repository_name" {
  value = aws_ecr_repository.client_proxy.name
}

output "clickhouse_migrator_repository_name" {
  value = aws_ecr_repository.clickhouse_migrator.name
}

output "custom_environments_repository_name" {
  value = aws_ecr_repository.custom_environments.name
}

output "api_repository_name" {
  value = aws_ecr_repository.api.name
}

output "db_migrator_repository_name" {
  value = aws_ecr_repository.db_migrator.name
}

// ---
// Network
// ---
output "vpc_id" {
  value = module.network.vpc_id
}

output "vpc_public_subnet_ids" {
  value = module.network.vpc_public_subnet_ids
}

output "vpc_private_subnet_ids" {
  value = module.network.vpc_private_subnets
}

output "vpc_private_ingress_subnet_ids" {
  value = module.network.vpc_private_ingress_subnet_ids
}

output "vpc_elasticache_subnet_group_name" {
  value = module.network.elasticache_subnet_group_name
}

output "vpc_data_subnet_ids" {
  description = "Isolated subnet IDs for managed data services"
  value       = module.network.elasticache_subnet_ids
}

output "vpc_instance_connect_security_group_id" {
  value = module.network.instance_connect_security_group_id
}

// ---
// KMS
// ---
output "ebs_kms_key_arn" {
  value = aws_kms_key.ebs.arn
}

output "rds_kms_key_arn" {
  value = aws_kms_key.rds.arn
}

output "s3_kms_key_arn" {
  value = aws_kms_key.s3.arn
}

output "kms_security_posture" {
  description = "Non-sensitive KMS and S3 controls exposed for policy tests"
  value = {
    ebs_key_rotation_enabled         = aws_kms_key.ebs.enable_key_rotation
    rds_key_rotation_enabled         = aws_kms_key.rds.enable_key_rotation
    s3_key_rotation_enabled          = aws_kms_key.s3.enable_key_rotation
    kms_encrypted_bucket_count       = length(aws_s3_bucket_server_side_encryption_configuration.kms)
    load_balancer_logs_sse_algorithm = one(aws_s3_bucket_server_side_encryption_configuration.load_balancer_logs.rule).apply_server_side_encryption_by_default[0].sse_algorithm
  }
}
