variable "prefix" {
  type = string
}

variable "name" {
  type    = string
  default = "postgres"
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "PostgreSQL requires subnets in at least two availability zones."
  }
}

variable "ingress_security_group_ids" {
  type = list(string)
}

variable "connection_string_secret_id" {
  type = string
}

variable "kms_key_arn" {
  type        = string
  description = "Customer-managed KMS key ARN for PostgreSQL storage and snapshots"
}

variable "database_name" {
  type    = string
  default = "e2b"
}

variable "master_username" {
  type    = string
  default = "e2b"
}

variable "port" {
  type    = number
  default = 5432
}

variable "engine_version" {
  type    = string
  default = "16.11"
}

variable "instance_class" {
  type    = string
  default = "db.t4g.small"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "max_allocated_storage" {
  type    = number
  default = 100
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "backup_retention_period" {
  type    = number
  default = 7
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "skip_final_snapshot" {
  type    = bool
  default = false
}
