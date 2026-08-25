variable "prefix" {
  type = string
}

variable "bucket_prefix" {
  type = string
}

variable "allow_force_destroy" {
  default = false
}

variable "docker_reverse_proxy_enabled" {
  type    = bool
  default = true
}

variable "region" {
  type = string
}

variable "endpoint_ingress_security_group_ids" {
  type = list(string)
}

variable "vpc_availability_zones" {
  type = list(string)
}

variable "vpc_cidr" {
  type = string
}

variable "vpc_public_subnets" {
  type = list(string)
}

variable "vpc_private_subnets" {
  type = list(string)
}

variable "vpc_elasticache_subnets" {
  type = list(string)
}

variable "use_instance_connect" {
  type = bool
}
