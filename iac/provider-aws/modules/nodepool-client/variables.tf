variable "prefix" {
  type = string
}

variable "name" {
  type = string
}

variable "aws_account_id" {
  type = string
}

variable "cluster_tag_name" {
  type = string
}

variable "cluster_tag_value" {
  type = string
}

variable "cluster_node_policy_arn" {
  type        = string
  description = "ARN of the base cluster node IAM policy"
}

variable "cluster_node_ec2_policy_json" {
  type        = string
  description = "JSON of the EC2 assume role policy document"
}

variable "setup_bucket_name" {
  type = string
}

variable "setup_files_hash" {
  type = map(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "vpc_private_subnets" {
  type = list(string)
}

variable "image_family_prefix" {
  type    = string
  default = "e2b-orch-"
}

variable "cluster_size" {
  type    = number
  default = 1
}

variable "max_cluster_size" {
  description = "Null keeps a fixed-size pool; a larger value enables scale-out only."
  type        = number
  default     = null

  validation {
    condition     = var.max_cluster_size == null ? true : var.max_cluster_size >= var.cluster_size && floor(var.max_cluster_size) == var.max_cluster_size
    error_message = "The maximum size must be an integer at least cluster_size."
  }
}

variable "reserved_host_memory_mib" {
  description = "Explicit host RAM reserve. Null retains the build-node percentage-based reserve."
  type        = number
  default     = null
}

variable "machine_type" {
  type    = string
  default = "m8i.4xlarge"
}

variable "ebs_kms_key_arn" {
  type = string
}

variable "node_pool_name" {
  type        = string
  description = "Nomad node pool name for client nodes"
}

variable "node_labels" {
  description = "Labels to assign to nodes for scheduling purposes"
  type        = list(string)
}

variable "sandbox_memory_limit_mib" {
  description = "Full guest memory commitment limit; zero disables admission."
  type        = number
  default     = 0
}

variable "max_sandboxes_per_node" {
  description = "VM commitment limit, including starts and teardown; zero disables admission."
  type        = number
  default     = 0
}

variable "base_hugepages_percentage" {
  description = "The percentage of memory to use for preallocated hugepages."
  type        = number
  default     = 60
}

variable "nested_virtualization" {
  type    = bool
  default = true
}

variable "boot_disk_size_gb" {
  type        = number
  default     = 500
  description = "Root volume size in GB"
}

variable "consul_acl_token" {
  type = string
}

variable "consul_gossip_encryption_key" {
  type = string
}

variable "consul_dns_request_token" {
  type = string
}

variable "aws_ecr_account_repository_domain" {
  type = string
}

variable "fc_kernels_bucket_name" {
  type = string
}

variable "fc_versions_bucket_name" {
  type = string
}

variable "fc_env_pipeline_bucket_name" {
  type = string
}

variable "fc_busybox_bucket_name" {
  type = string
}

variable "fc_env_pipeline_bucket_arn" {
  type = string
}

variable "fc_kernels_bucket_arn" {
  type = string
}

variable "fc_versions_bucket_arn" {
  type = string
}

variable "fc_busybox_bucket_arn" {
  type = string
}

variable "templates_bucket_arn" {
  type = string
}

variable "templates_build_cache_bucket_arn" {
  type = string
}

variable "custom_environments_repo_arn" {
  type = string
}

variable "scripts_path" {
  type        = string
  description = "Path to the directory containing startup scripts. Defaults to in-module scripts."
  default     = ""
}

variable "use_instance_store" {
  description = "Mount a dedicated local NVMe instance-store disk as the orchestrator XFS cache. Requires an instance type with local storage."
  type        = bool
  default     = false
}
