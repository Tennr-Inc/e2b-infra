variable "domain_name" {
  type        = string
  description = "Private DNS suffix used by the API, Nomad UI, and sandbox wildcard hostnames"
}

variable "aws_account_id" {
  type        = string
  description = "AWS account that Terraform is allowed to modify"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit AWS account ID."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region for the E2B deployment"
}

variable "ingress_certificate_arn" {
  type        = string
  description = "Existing ACM certificate ARN covering the private wildcard domain; leave empty to request a DNS-validated certificate"
  default     = ""

  validation {
    condition     = var.ingress_certificate_arn == "" || can(regex("^arn:aws[a-zA-Z-]*:acm:", var.ingress_certificate_arn))
    error_message = "ingress_certificate_arn must be empty or an ACM certificate ARN."
  }
}

variable "ingress_certificate_validation_zone_id" {
  type        = string
  description = "Optional public Route53 hosted zone ID where Terraform should create ACM validation records"
  default     = ""

  validation {
    condition     = var.ingress_certificate_validation_zone_id == "" || can(regex("^Z[A-Z0-9]+$", var.ingress_certificate_validation_zone_id))
    error_message = "ingress_certificate_validation_zone_id must be empty or a Route53 hosted zone ID."
  }
}

variable "privatelink_allowed_principal_arns" {
  type        = list(string)
  description = "AWS principals allowed to create interface endpoints to the E2B endpoint service; normally the root principal of each Tennr consumer account"

  validation {
    condition = length(var.privatelink_allowed_principal_arns) > 0 && alltrue([
      for principal_arn in var.privatelink_allowed_principal_arns : can(regex("^arn:aws[a-zA-Z-]*:iam::[0-9]{12}:(root|role/.+)$", principal_arn))
    ])
    error_message = "privatelink_allowed_principal_arns must contain at least one IAM root or role ARN."
  }
}

variable "enable_load_balancer_deletion_protection" {
  type        = bool
  description = "Protect the private ALB and PrivateLink NLB from accidental deletion"
  default     = false
}

variable "vpc_cidr" {
  type        = string
  description = "Non-overlapping CIDR for the dedicated E2B VPC"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR."
  }
}

variable "vpc_availability_zones" {
  type        = list(string)
  description = "Three availability zones used by the E2B VPC"

  validation {
    condition     = length(var.vpc_availability_zones) == 3
    error_message = "Exactly three availability zones are required."
  }
}

variable "vpc_public_subnets" {
  type        = list(string)
  description = "Three public subnet CIDRs used only for NAT gateways"

  validation {
    condition     = length(var.vpc_public_subnets) == 3
    error_message = "Exactly three public subnet CIDRs are required."
  }
}

variable "vpc_private_subnets" {
  type        = list(string)
  description = "Private subnet CIDRs for E2B nodes and the internal ALB"

  validation {
    condition     = length(var.vpc_private_subnets) >= 3
    error_message = "At least three private subnet CIDRs are required."
  }
}

variable "vpc_elasticache_subnets" {
  type        = list(string)
  description = "Three isolated subnet CIDRs for managed Redis"

  validation {
    condition     = length(var.vpc_elasticache_subnets) == 3
    error_message = "Exactly three ElastiCache subnet CIDRs are required."
  }
}

variable "use_instance_connect" {
  type        = bool
  description = "Create an EC2 Instance Connect endpoint for private node administration"
  default     = true
}

variable "allow_force_destroy" {
  default = false
}

variable "kms_key_deletion_window_days" {
  type        = number
  description = "Waiting period before a scheduled E2B customer-managed KMS key deletion"
  default     = 30

  validation {
    condition     = var.kms_key_deletion_window_days >= 7 && var.kms_key_deletion_window_days <= 30
    error_message = "kms_key_deletion_window_days must be between 7 and 30."
  }
}

variable "prefix" {
  type        = string
  description = "Name prefix for all resources"
}

variable "bucket_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "docker_reverse_proxy_enabled" {
  type        = bool
  default     = true
  description = "Whether to create the docker-reverse-proxy ECR repository. The component is deprecated and no AWS Nomad job consumes this repository; set to false to stop creating it."
}

variable "redis_managed" {
  type    = bool
  default = false
}

variable "redis_instance_type" {
  type    = string
  default = "cache.t4g.small"
}

variable "redis_replica_size" {
  type    = number
  default = 2

  validation {
    condition     = var.redis_replica_size >= 2
    error_message = "Managed Redis requires at least two nodes for automatic failover."
  }
}

variable "postgres_engine_version" {
  type        = string
  description = "Pinned PostgreSQL engine version"
  default     = "16.11"
}

variable "postgres_admin_ingress_security_group_ids" {
  type        = list(string)
  description = "Additional security groups allowed to administer private RDS, such as a Twingate connector in the E2B VPC"
  default     = []

  validation {
    condition = alltrue([
      for security_group_id in var.postgres_admin_ingress_security_group_ids : can(regex("^sg-[0-9a-f]+$", security_group_id))
    ])
    error_message = "postgres_admin_ingress_security_group_ids must contain only AWS security group IDs."
  }
}

variable "postgres_instance_class" {
  type    = string
  default = "db.t4g.small"
}

variable "postgres_allocated_storage" {
  type    = number
  default = 20
}

variable "postgres_max_allocated_storage" {
  type    = number
  default = 100
}

variable "postgres_multi_az" {
  type    = bool
  default = false
}

variable "postgres_backup_retention_period" {
  type    = number
  default = 7
}

variable "postgres_deletion_protection" {
  type    = bool
  default = true
}

variable "postgres_skip_final_snapshot" {
  type    = bool
  default = false
}

variable "api_cluster_size" {
  type    = number
  default = 1
}

variable "api_internal_grpc_port" {
  type    = number
  default = 5009
}

variable "api_env_vars" {
  type      = map(string)
  default   = {}
  sensitive = true
}

variable "api_db_migrator_env_vars" {
  type      = map(string)
  default   = {}
  sensitive = true
}

variable "client_proxy_env_vars" {
  type      = map(string)
  default   = {}
  sensitive = true
}

variable "orchestrator_env_vars" {
  type      = map(string)
  default   = {}
  sensitive = true
}

variable "template_manager_env_vars" {
  type      = map(string)
  default   = {}
  sensitive = true
}

variable "s3_use_path_style" {
  type        = bool
  default     = false
  description = "When true, use path-style S3 addressing (https://host/bucket/key). When false (default), use virtual-host-style (https://bucket.host/key). Set to true for S3-compatible backends (MinIO, Ceph, etc.) that don't support virtual-host addressing."
}

variable "api_server_machine_type" {
  type    = string
  default = "t3.xlarge"
}

variable "api_image_family_prefix" {
  type    = string
  default = ""
}

variable "ingress_count" {
  type    = number
  default = 1
}

variable "client_proxy_count" {
  type    = number
  default = 1
}

variable "clickhouse_cluster_size" {
  type    = number
  default = 1
}

variable "clickhouse_server_machine_type" {
  type    = string
  default = "t3.xlarge"
}

variable "clickhouse_image_family_prefix" {
  type    = string
  default = ""
}

variable "client_cluster_size" {
  type    = number
  default = 1
}

variable "client_server_machine_type" {
  type    = string
  default = "m8i.4xlarge"
}

variable "client_server_nested_virtualization" {
  type    = bool
  default = true
}

variable "client_node_labels" {
  description = "Labels to assign to client nodes for scheduling purposes"
  type        = list(string)
  default     = []
}

variable "client_image_family_prefix" {
  type    = string
  default = ""
}

variable "control_server_machine_type" {
  type    = string
  default = "t3.medium"
}

variable "control_server_image_family_prefix" {
  type    = string
  default = ""
}

variable "orchestrator_port" {
  type    = number
  default = 5008
}

variable "orchestrator_proxy_port" {
  type    = number
  default = 5007
}

variable "allow_sandbox_internal_cidrs" {
  type        = string
  description = "Comma-separated CIDRs to allow through the sandbox firewall deny list (e.g. 10.0.0.1/32,10.0.0.2/32)"
  default     = ""
}

variable "envd_timeout" {
  type    = string
  default = "40s"
}

variable "build_cluster_size" {
  type    = number
  default = 1
}

variable "build_server_machine_type" {
  type    = string
  default = "m8i.4xlarge"
}

variable "build_server_nested_virtualization" {
  type    = bool
  default = true
}

variable "build_node_labels" {
  description = "Labels to assign to build nodes for scheduling purposes"
  type        = list(string)
  default     = []
}

variable "control_server_cluster_size" {
  type    = number
  default = 3
}

variable "traefik_config_files" {
  type        = map(string)
  description = "Map of filename => content for additional Traefik dynamic configuration files"
  default     = {}
}

variable "db_max_open_connections" {
  type    = number
  default = 40
}

variable "db_min_idle_connections" {
  type    = number
  default = 5
}

variable "auth_db_max_open_connections" {
  type    = number
  default = 20
}

variable "auth_db_min_idle_connections" {
  type    = number
  default = 5
}

variable "enable_otel_router_logs" {
  type        = bool
  default     = false
  description = "Enable teeing non-internal customer logs from Vector to otel-router."
}

variable "otel_router_http_port" {
  type        = number
  default     = 4321
  description = "Local otel-router Vector-compatible logs port used by Vector when otel-router log teeing is enabled."
}

variable "enable_otel_router_metrics" {
  type        = bool
  default     = false
  description = "Enable teeing external customer metrics from otel-collector to otel-router."
}

variable "otel_router_grpc_port" {
  type        = number
  default     = 4320
  description = "Local otel-router OTLP gRPC port used by otel-collector when otel-router metric teeing is enabled."
}
