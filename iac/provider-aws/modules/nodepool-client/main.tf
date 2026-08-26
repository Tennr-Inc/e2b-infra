locals {
  scripts_path        = var.scripts_path != "" ? var.scripts_path : "${path.module}/scripts"
  autoscaling_enabled = coalesce(var.max_cluster_size, var.cluster_size) > var.cluster_size
  admission_enabled   = var.sandbox_memory_limit_mib > 0 && var.max_sandboxes_per_node > 0

  user_data = templatefile("${local.scripts_path}/start-client.sh", {
    INSTANCE_STORE_SETUP = var.use_instance_store ? join("\n", [
      "install -d -m 0755 /opt/e2b/bin",
      "touch /opt/e2b/instance-store-required",
      "aws s3 cp s3://${var.setup_bucket_name}/${aws_s3_object.instance_store_setup[0].key} /opt/e2b/bin/instance-store.py",
      "python3 /opt/e2b/bin/instance-store.py",
    ]) : ""
    NODE_POOL                    = var.node_pool_name
    CLUSTER_TAG_NAME             = var.cluster_tag_name
    CLUSTER_TAG_VALUE            = var.cluster_tag_value
    SCRIPTS_BUCKET               = var.setup_bucket_name
    CONSUL_TOKEN                 = var.consul_acl_token
    CONSUL_GOSSIP_ENCRYPTION_KEY = var.consul_gossip_encryption_key
    CONSUL_DNS_REQUEST_TOKEN     = var.consul_dns_request_token

    FC_KERNELS_BUCKET_NAME      = var.fc_kernels_bucket_name
    FC_VERSIONS_BUCKET_NAME     = var.fc_versions_bucket_name
    FC_ENV_PIPELINE_BUCKET_NAME = var.fc_env_pipeline_bucket_name
    FC_BUSYBOX_BUCKET_NAME      = var.fc_busybox_bucket_name
    NODE_LABELS                 = join(",", var.node_labels)
    BASE_HUGEPAGES_PERCENTAGE   = var.base_hugepages_percentage
    SANDBOX_MEMORY_LIMIT_MIB    = var.sandbox_memory_limit_mib
    MAX_SANDBOXES_PER_NODE      = var.max_sandboxes_per_node
    RESERVED_HOST_MEMORY_MIB    = coalesce(var.reserved_host_memory_mib, 0)
    HUGEPAGES_SCRIPT_BASE64     = filebase64("${path.module}/scripts/hugepages.sh")
    PREPARE_HOST_SCRIPT_BASE64  = filebase64("${path.module}/scripts/prepare-host.sh")
    CAPACITY_REPORTER_SETUP = local.autoscaling_enabled ? templatefile("${path.module}/scripts/install-capacity-reporter.sh.tftpl", {
      reporter_base64   = filebase64("${path.module}/scripts/report-capacity.py")
      asg_name          = "${var.prefix}${var.name}"
      aws_region        = data.aws_region.current.id
      admission_enabled = local.admission_enabled
    }) : ""

    AWS_ECR_ACCOUNT_REPOSITORY_DOMAIN = var.aws_ecr_account_repository_domain

    RUN_CONSUL_FILE_HASH = var.setup_files_hash["run-consul"]
    RUN_NOMAD_FILE_HASH  = var.setup_files_hash["run-nomad"]
  })
}

resource "aws_s3_object" "instance_store_setup" {
  count  = var.use_instance_store ? 1 : 0
  bucket = var.setup_bucket_name
  key    = "instance-store-${filesha256("${path.module}/scripts/instance-store.py")}.py"
  source = "${path.module}/scripts/instance-store.py"
}

resource "aws_iam_policy" "client_node_policy" {
  name   = "${var.prefix}${var.name}-node-policy"
  policy = data.aws_iam_policy_document.client_node_policy.json
}

data "aws_iam_policy_document" "client_node_policy" {
  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchDeleteImage",
      "ecr:DescribeRepositories",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage"
    ]
    resources = [
      var.custom_environments_repo_arn
    ]
  }

  // Allow read access from binaries buckets
  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = [
      "${var.fc_env_pipeline_bucket_arn}/*",
      var.fc_env_pipeline_bucket_arn,

      "${var.fc_kernels_bucket_arn}/*",
      var.fc_kernels_bucket_arn,

      "${var.fc_versions_bucket_arn}/*",
      var.fc_versions_bucket_arn,

      "${var.fc_busybox_bucket_arn}/*",
      var.fc_busybox_bucket_arn,
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      // Templates
      "${var.templates_bucket_arn}/*",
      var.templates_bucket_arn,

      // Template build cache
      "${var.templates_build_cache_bucket_arn}/*",
      var.templates_build_cache_bucket_arn,
    ]
  }
}

resource "aws_iam_role" "client" {
  name               = "${var.prefix}${var.name}-node"
  assume_role_policy = var.cluster_node_ec2_policy_json
}

resource "aws_iam_role_policy_attachment" "client" {
  for_each = {
    "cluster-node" = var.cluster_node_policy_arn
    "client-node"  = aws_iam_policy.client_node_policy.arn
  }

  role       = aws_iam_role.client.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "client" {
  name = "${var.prefix}${var.name}-node"
  role = aws_iam_role.client.name
}

data "aws_ami" "client" {
  most_recent = true
  owners      = [var.aws_account_id]

  filter {
    name   = "name"
    values = ["${var.image_family_prefix}*"]
  }
}

resource "aws_launch_template" "client" {
  name          = "${var.prefix}${var.name}-node"
  image_id      = data.aws_ami.client.id
  instance_type = var.machine_type
  lifecycle {
    precondition {
      condition = (
        var.sandbox_memory_limit_mib == 0 && var.max_sandboxes_per_node == 0 ||
        var.sandbox_memory_limit_mib > 0 && var.max_sandboxes_per_node > 0 && var.base_hugepages_percentage > 0
      )
      error_message = "Set both positive sandbox admission limits and a preallocated pool, or leave both limits zero."
    }
  }
  # The capacity reporter also pushes EBS-backed worker bootstrap past EC2's
  # 16 KiB limit. Cloud-init accepts gzip for both worker cache configurations.
  user_data = base64gzip(local.user_data)

  monitoring {
    enabled = local.autoscaling_enabled
  }

  vpc_security_group_ids = var.security_group_ids

  metadata_options {
    http_tokens = "required"
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.client.name
  }

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = var.boot_disk_size_gb
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
      kms_key_id            = var.ebs_kms_key_arn
    }
  }

  cpu_options {
    nested_virtualization = var.nested_virtualization ? "enabled" : "disabled"
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.prefix}${var.name}"

      // Tag to identify Nomad cluster members so auto-join can work
      (var.cluster_tag_name) = var.cluster_tag_value
    }
  }
}

resource "aws_autoscaling_group" "client" {
  name                = "${var.prefix}${var.name}"
  vpc_zone_identifier = var.vpc_private_subnets
  health_check_type   = "EC2"

  min_size                = var.cluster_size
  max_size                = coalesce(var.max_cluster_size, var.cluster_size)
  default_instance_warmup = local.autoscaling_enabled ? 600 : null
  protect_from_scale_in   = local.autoscaling_enabled

  launch_template {
    id      = aws_launch_template.client.id
    version = aws_launch_template.client.latest_version
  }

  // Do not wait for slow EC2 Metal instance to terminate before detaching from ASG
  force_delete           = true
  force_delete_warm_pool = true

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}
