resource "aws_security_group" "privatelink_nlb" {
  name        = "${var.prefix}privatelink-nlb"
  description = "PrivateLink network load balancer"
  vpc_id      = module.init.vpc_id

  egress {
    description = "Forward TLS to the internal ALB"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${var.prefix}privatelink-nlb"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_privatelink" {
  security_group_id            = aws_security_group.ingress.id
  referenced_security_group_id = aws_security_group.privatelink_nlb.id
  description                  = "HTTPS from the PrivateLink NLB"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_lb" "privatelink" {
  name               = "${var.prefix}privatelink"
  internal           = true
  load_balancer_type = "network"
  subnets            = module.init.vpc_private_ingress_subnet_ids
  security_groups    = [aws_security_group.privatelink_nlb.id]

  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = var.enable_load_balancer_deletion_protection

  # PrivateLink endpoint traffic is authorized at the endpoint service and
  # consumer endpoint SG. The NLB still uses its SG for traffic to the ALB.
  enforce_security_group_inbound_rules_on_private_link_traffic = "off"
}

resource "aws_lb_target_group" "privatelink_alb" {
  name        = "${var.prefix}privatelink-alb"
  port        = 443
  protocol    = "TCP"
  target_type = "alb"
  vpc_id      = module.init.vpc_id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 10
    matcher             = "200"
    path                = "/ping"
    port                = "443"
    protocol            = "HTTPS"
    timeout             = 5
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group_attachment" "privatelink_alb" {
  target_group_arn = aws_lb_target_group.privatelink_alb.arn
  target_id        = aws_lb.ingress.arn
  port             = 443

  depends_on = [aws_lb_listener.ingress_wildcard]
}

resource "aws_lb_listener" "privatelink" {
  load_balancer_arn = aws_lb.privatelink.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.privatelink_alb.arn
  }
}

resource "aws_vpc_endpoint_service" "ingress" {
  acceptance_required        = false
  network_load_balancer_arns = [aws_lb.privatelink.arn]

  tags = {
    Name = "${var.prefix}ingress"
  }
}

resource "aws_vpc_endpoint_service_allowed_principal" "consumer" {
  for_each = toset(var.privatelink_allowed_principal_arns)

  vpc_endpoint_service_id = aws_vpc_endpoint_service.ingress.id
  principal_arn           = each.value
}
