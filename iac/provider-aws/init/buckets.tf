resource "aws_s3_bucket" "setup" {
  bucket        = "${var.bucket_prefix}instance-setup"
  force_destroy = var.allow_force_destroy
}

resource "aws_s3_bucket" "fc_kernels" {
  bucket        = "${var.bucket_prefix}fc-kernels"
  force_destroy = var.allow_force_destroy
}

resource "aws_s3_bucket" "fc_versions" {
  bucket        = "${var.bucket_prefix}fc-versions"
  force_destroy = var.allow_force_destroy
}

resource "aws_s3_bucket" "fc_env_pipeline" {
  bucket        = "${var.bucket_prefix}fc-env-pipeline"
  force_destroy = var.allow_force_destroy
}

resource "aws_s3_bucket" "fc_busybox" {
  bucket        = "${var.bucket_prefix}fc-busybox"
  force_destroy = var.allow_force_destroy
}

resource "aws_s3_bucket" "fc_templates" {
  bucket        = "${var.bucket_prefix}fc-templates"
  force_destroy = var.allow_force_destroy
}

resource "aws_s3_bucket" "fc_template_build_cache" {
  bucket        = "${var.bucket_prefix}fc-build-cache"
  force_destroy = var.allow_force_destroy
}

# ---
# Loki
# ---

resource "aws_s3_bucket" "loki_storage" {
  bucket        = "${var.bucket_prefix}loki-storage"
  force_destroy = var.allow_force_destroy
}

resource "aws_s3_bucket_lifecycle_configuration" "loki_storage" {
  bucket = aws_s3_bucket.loki_storage.id

  rule {
    id = "expire-objects-older-than-8-days"

    filter {
      prefix = ""
    }

    expiration {
      days = 8
    }

    status = "Enabled"
  }
}

# ---
# Load Balancer Logs
# ---

resource "aws_s3_bucket" "load_balancer_logs" {
  bucket        = "${var.bucket_prefix}load-balancer-logs"
  force_destroy = var.allow_force_destroy
}

resource "aws_s3_bucket_lifecycle_configuration" "load_balancer_logs" {
  bucket = aws_s3_bucket.load_balancer_logs.id

  rule {
    id = "expire-logs-older-than-90-days"

    filter {
      prefix = ""
    }

    expiration {
      days = 90
    }

    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "load_balancer_logs" {
  bucket = aws_s3_bucket.load_balancer_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "load_balancer_logs" {
  statement {
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.current.arn]
    }

    actions = [
      "s3:PutObject"
    ]

    resources = [
      "${aws_s3_bucket.load_balancer_logs.arn}/*",
    ]
  }
}

resource "aws_s3_bucket_policy" "load_balancer_logs" {
  bucket = aws_s3_bucket.load_balancer_logs.id
  policy = data.aws_iam_policy_document.load_balancer_logs.json
}

# ---
# Clickhouse
# ---

resource "aws_s3_bucket" "clickhouse_backups" {
  bucket        = "${var.bucket_prefix}clickhouse-backups"
  force_destroy = var.allow_force_destroy
}

resource "aws_s3_bucket_lifecycle_configuration" "clickhouse_backups" {
  bucket = aws_s3_bucket.clickhouse_backups.id

  rule {
    id = "expire-objects-older-than-30-days"

    filter {
      prefix = ""
    }

    expiration {
      days = 30
    }

    status = "Enabled"
  }
}

# ---
# Customer-managed encryption
# ---

locals {
  kms_encrypted_bucket_ids = {
    clickhouse_backups      = aws_s3_bucket.clickhouse_backups.id
    fc_busybox              = aws_s3_bucket.fc_busybox.id
    fc_env_pipeline         = aws_s3_bucket.fc_env_pipeline.id
    fc_kernels              = aws_s3_bucket.fc_kernels.id
    fc_template_build_cache = aws_s3_bucket.fc_template_build_cache.id
    fc_templates            = aws_s3_bucket.fc_templates.id
    fc_versions             = aws_s3_bucket.fc_versions.id
    loki_storage            = aws_s3_bucket.loki_storage.id
    setup                   = aws_s3_bucket.setup.id
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "kms" {
  for_each = local.kms_encrypted_bucket_ids

  bucket = each.value

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3.arn
      sse_algorithm     = "aws:kms"
    }
  }
}
