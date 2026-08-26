locals {
  manage_ingress_certificate     = var.ingress_certificate_arn == ""
  manage_ingress_certificate_dns = local.manage_ingress_certificate && var.ingress_certificate_validation_zone_id != ""
  ingress_certificate_arn = local.manage_ingress_certificate ? (
    aws_acm_certificate.ingress[0].arn
  ) : var.ingress_certificate_arn
}

resource "aws_acm_certificate" "ingress" {
  count = local.manage_ingress_certificate ? 1 : 0

  domain_name       = "*.${var.domain_name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.prefix}private-ingress"
  }
}

resource "aws_route53_record" "ingress_certificate_validation" {
  for_each = local.manage_ingress_certificate_dns ? {
    for option in aws_acm_certificate.ingress[0].domain_validation_options : option.domain_name => {
      name   = option.resource_record_name
      type   = option.resource_record_type
      record = option.resource_record_value
    }
  } : {}

  allow_overwrite = true
  zone_id         = var.ingress_certificate_validation_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
}

# If the authoritative public zone is outside this AWS account, leave
# ingress_certificate_validation_zone_id empty, publish the record printed by
# `make request-certificate`, and this resource will wait for ACM to observe it.
resource "aws_acm_certificate_validation" "ingress" {
  count = local.manage_ingress_certificate ? 1 : 0

  certificate_arn         = aws_acm_certificate.ingress[0].arn
  validation_record_fqdns = local.manage_ingress_certificate_dns ? values(aws_route53_record.ingress_certificate_validation)[*].fqdn : null

  timeouts {
    create = "60m"
  }
}
