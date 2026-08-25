variable "prefix" {
  type = string
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
}

variable "vpc_public_subnets" {
  type        = list(string)
  description = "CIDRs for the public subnets in the VPC, at least three are required"
}

variable "vpc_private_subnets" {
  type        = list(string)
  description = "CIDRs for the private subnets in the VPC, at least three are required"
}

variable "vpc_elasticache_subnets" {
  type = list(string)
}

variable "vpc_availability_zones" {
  type        = list(string)
  description = "List of availability zones to use for the VPC subnets"
}

variable "vpc_endpoint_ingress_security_group_ids" {
  type = list(string)
}

variable "use_instance_connect" {
  type        = bool
  default     = true
  description = "Whether to deploy AWS EC2 Instance Connect Endpoint for SSH access to EC2 instances"
}
