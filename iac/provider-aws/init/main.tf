data "aws_region" "current" {}

data "aws_elb_service_account" "current" {}

module "network" {
  source = "../modules/network"

  prefix                                  = var.prefix
  vpc_availability_zones                  = var.vpc_availability_zones
  vpc_cidr                                = var.vpc_cidr
  vpc_public_subnets                      = var.vpc_public_subnets
  vpc_private_subnets                     = var.vpc_private_subnets
  vpc_elasticache_subnets                 = var.vpc_elasticache_subnets
  vpc_endpoint_ingress_security_group_ids = var.endpoint_ingress_security_group_ids
  use_instance_connect                    = var.use_instance_connect
}
