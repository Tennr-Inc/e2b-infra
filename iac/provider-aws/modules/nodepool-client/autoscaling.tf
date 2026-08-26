data "aws_region" "current" {}

resource "aws_iam_role_policy" "capacity_metrics" {
  count = local.autoscaling_enabled ? 1 : 0

  name = "sandbox-capacity-metrics"
  role = aws_iam_role.client.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "cloudwatch:PutMetricData"
      Resource = "*"
      Condition = {
        StringEquals = { "cloudwatch:namespace" = "E2B/Capacity" }
      }
    }]
  })
}

resource "aws_autoscaling_policy" "memory" {
  count = local.autoscaling_enabled ? 1 : 0

  name                   = "${var.prefix}${var.name}-memory"
  autoscaling_group_name = aws_autoscaling_group.client.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    target_value     = 70
    disable_scale_in = true

    customized_metric_specification {
      namespace = "E2B/Capacity"
      # Separate series prevents legacy resident-memory samples from diluting
      # commitment-based samples during a worker rollout.
      metric_name = local.admission_enabled ? "SandboxCapacityUtilization" : "SandboxMemoryUtilization"
      statistic   = "Average"
      unit        = "Percent"

      metric_dimension {
        name  = "AutoScalingGroupName"
        value = aws_autoscaling_group.client.name
      }
    }
  }
}

resource "aws_autoscaling_policy" "cpu" {
  count = local.autoscaling_enabled ? 1 : 0

  name                   = "${var.prefix}${var.name}-cpu"
  autoscaling_group_name = aws_autoscaling_group.client.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    target_value     = 70
    disable_scale_in = true

    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
  }
}
