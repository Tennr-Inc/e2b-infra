locals {
  manage_ingress_certificate = var.ingress_certificate_arn == ""
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

# The validation CNAME deliberately lives outside this configuration. It must
# be publicly resolvable for ACM, but it does not route traffic or expose the
# internal ALB. Use `make request-certificate` to print the record, publish it
# in the authoritative DNS provider, and then run the normal full apply.
resource "aws_acm_certificate_validation" "ingress" {
  count = local.manage_ingress_certificate ? 1 : 0

  certificate_arn = aws_acm_certificate.ingress[0].arn

  timeouts {
    create = "60m"
  }
}
