resource "aws_security_group" "ingress" {
  name   = "${var.prefix}ingress-load-balancer"
  vpc_id = module.init.vpc_id

  dynamic "ingress" {
    for_each = toset(var.ingress_allowed_cidr_blocks)

    content {
      description = "Private HTTPS ingress from ${ingress.value}"
      from_port   = 443
      to_port     = 443
      protocol    = "TCP"
      cidr_blocks = [ingress.value]
    }
  }

  dynamic "ingress" {
    for_each = toset(var.ingress_allowed_security_group_ids)
    iterator = source_security_group

    content {
      description     = "Private HTTPS ingress from ${source_security_group.value}"
      from_port       = 443
      to_port         = 443
      protocol        = "TCP"
      security_groups = [source_security_group.value]
    }
  }

  egress {
    description = "Forward application traffic to API nodes"
    from_port   = local.ingress_port
    to_port     = local.ingress_port
    protocol    = "TCP"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Forward Nomad UI traffic to control nodes"
    from_port   = local.nomad_port
    to_port     = local.nomad_port
    protocol    = "TCP"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${var.prefix}ingress-load-balancer"
  }

  lifecycle {
    precondition {
      condition     = length(var.ingress_allowed_cidr_blocks) > 0 || length(var.ingress_allowed_security_group_ids) > 0
      error_message = "Configure at least one private CIDR or security group for HTTPS ingress."
    }
  }
}

resource "aws_lb" "ingress" {
  name                       = "${var.prefix}ingress"
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = module.init.vpc_private_ingress_subnet_ids
  drop_invalid_header_fields = true
  enable_deletion_protection = var.enable_alb_deletion_protection
  security_groups = [
    aws_security_group.ingress.id
  ]

  access_logs {
    bucket  = data.aws_s3_bucket.load_balancer_logs.id
    prefix  = local.ingress_logs_path_prefix
    enabled = true
  }
}

resource "aws_lb_listener" "ingress_wildcard" {
  load_balancer_arn = aws_lb.ingress.arn

  port     = "443"
  protocol = "HTTPS"

  ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn = local.ingress_certificate_arn

  depends_on = [aws_acm_certificate_validation.ingress]

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingress.arn
  }
}

resource "aws_lb_listener_rule" "ingress_grpc" {
  listener_arn = aws_lb_listener.ingress_wildcard.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingress_grpc.arn
  }

  condition {
    http_header {
      http_header_name = "content-type"
      values           = ["application/grpc*"]
    }
  }
}

resource "aws_lb_listener_rule" "nomad" {
  listener_arn = aws_lb_listener.ingress_wildcard.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nomad.arn
  }

  condition {
    host_header {
      values = [
        "nomad.${var.domain_name}"
      ]
    }
  }
}

resource "aws_lb_target_group" "ingress" {
  name   = "${var.prefix}ingress"
  port   = local.ingress_port
  vpc_id = module.init.vpc_id

  protocol         = "HTTP"
  protocol_version = "HTTP1"
  target_type      = "instance"

  deregistration_delay = 30

  health_check {
    path                = "/ping"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 5
    timeout             = 2
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group" "ingress_grpc" {
  name   = "${var.prefix}ingress-grpc"
  port   = local.ingress_port
  vpc_id = module.init.vpc_id

  protocol         = "HTTP"
  protocol_version = "GRPC"
  target_type      = "instance"

  deregistration_delay = 30

  health_check {
    path                = "/ping"
    protocol            = "HTTP"
    matcher             = "0"
    interval            = 5
    timeout             = 2
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group" "nomad" {
  name   = "${var.prefix}nomad"
  port   = local.nomad_port
  vpc_id = module.init.vpc_id

  protocol         = "HTTP"
  protocol_version = "HTTP1"
  target_type      = "instance"

  deregistration_delay = 30

  health_check {
    path                = "/v1/status/peers"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 5
    timeout             = 2
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}
