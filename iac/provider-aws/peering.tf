locals {
  peering_enabled = var.peer_vpc_id != "" || var.peer_vpc_cidr != "" || length(var.peer_route_table_ids) > 0
}

resource "aws_vpc_peering_connection" "peer" {
  count = local.peering_enabled ? 1 : 0

  vpc_id      = module.init.vpc_id
  peer_vpc_id = var.peer_vpc_id
  auto_accept = true

  tags = {
    Name = "${var.prefix}staging-peer"
  }

  lifecycle {
    precondition {
      condition     = var.peer_vpc_id != "" && var.peer_vpc_cidr != "" && length(var.peer_route_table_ids) > 0
      error_message = "peer_vpc_id, peer_vpc_cidr, and at least one peer_route_table_id must be set when peering is enabled."
    }
  }
}

resource "aws_vpc_peering_connection_options" "peer" {
  count = local.peering_enabled ? 1 : 0

  vpc_peering_connection_id = aws_vpc_peering_connection.peer[0].id

  requester {
    allow_remote_vpc_dns_resolution = true
  }

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
}

resource "aws_route" "e2b_to_peer" {
  count = local.peering_enabled ? length(module.init.vpc_private_route_table_ids) : 0

  route_table_id            = module.init.vpc_private_route_table_ids[count.index]
  destination_cidr_block    = var.peer_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peer[0].id
}

resource "aws_route" "peer_to_e2b" {
  for_each = local.peering_enabled ? toset(var.peer_route_table_ids) : toset([])

  route_table_id            = each.value
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peer[0].id
}
