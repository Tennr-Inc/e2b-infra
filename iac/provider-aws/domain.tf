resource "aws_route53_zone" "private" {
  name = var.domain_name

  vpc {
    vpc_id = module.init.vpc_id
  }

  tags = {
    Name = "${var.prefix}private-zone"
  }
}

resource "aws_route53_record" "wildcard" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "*.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.ingress.dns_name
    zone_id                = aws_lb.ingress.zone_id
    evaluate_target_health = true
  }
}
