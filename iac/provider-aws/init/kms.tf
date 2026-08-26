data "aws_caller_identity" "current" {}

locals {
  kms_alias_prefix = trimsuffix(var.prefix, "-")
}

data "aws_iam_policy_document" "ebs_kms" {
  statement {
    sid    = "EnableAccountAdministration"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  # Auto Scaling launches and replaces every Nomad node. Restrict direct key
  # use to this account and to calls that pass through the regional EC2
  # service, instead of depending on a pre-existing service-linked-role ARN.
  statement {
    sid    = "AllowAccountEBSUseThroughEC2"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ec2.${var.region}.amazonaws.com"]
    }
  }

  statement {
    sid    = "AllowAutoScalingAWSResourceGrants"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions   = ["kms:CreateGrant"]
    resources = ["*"]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values = [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling",
      ]
    }
  }
}

resource "aws_kms_key" "ebs" {
  description             = "E2B EBS volumes and AMI snapshots"
  deletion_window_in_days = var.kms_key_deletion_window_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.ebs_kms.json
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/${local.kms_alias_prefix}-ebs"
  target_key_id = aws_kms_key.ebs.key_id
}

resource "aws_kms_key" "rds" {
  description             = "E2B RDS PostgreSQL storage and snapshots"
  deletion_window_in_days = var.kms_key_deletion_window_days
  enable_key_rotation     = true
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${local.kms_alias_prefix}-rds"
  target_key_id = aws_kms_key.rds.key_id
}

resource "aws_kms_key" "s3" {
  description             = "E2B S3 application data"
  deletion_window_in_days = var.kms_key_deletion_window_days
  enable_key_rotation     = true
}

resource "aws_kms_alias" "s3" {
  name          = "alias/${local.kms_alias_prefix}-s3"
  target_key_id = aws_kms_key.s3.key_id
}
