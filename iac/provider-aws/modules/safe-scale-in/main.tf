variable "name" { type = string }
variable "asg_name" { type = string }
variable "asg_arn" { type = string }
variable "minimum_nodes" {
  type    = number
  default = 2
  validation {
    condition     = var.minimum_nodes >= 1 && floor(var.minimum_nodes) == var.minimum_nodes
    error_message = "Keep at least one warm node."
  }
}
variable "dry_run" {
  type    = bool
  default = true
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  arn_prefix = "arn:${data.aws_partition.current.partition}"
  region     = data.aws_region.current.id
  account    = data.aws_caller_identity.current.account_id
}

resource "aws_dynamodb_table" "state" {
  name         = var.name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  attribute {
    name = "id"
    type = "S"
  }
  server_side_encryption { enabled = true }
  point_in_time_recovery { enabled = true }
}

# A fixed document exposes only the host-local retirement protocol. The Lambda
# cannot send arbitrary shell commands or invoke AWS-RunShellScript.
resource "aws_ssm_document" "retirement" {
  name          = var.name
  document_type = "Command"
  content = jsonencode({
    schemaVersion = "2.2"
    parameters = {
      action = {
        type          = "String"
        allowedValues = ["status", "drain", "seal", "cancel"]
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "retirement"
      inputs = {
        timeoutSeconds = "20"
        runCommand = [<<-PY
          python3 - <<'PYTHON'
          import urllib.request, urllib.error
          action = '{{ action }}'
          url = 'http://127.0.0.1:5008/retirement'
          method = 'GET'
          if action != 'status':
              url += '?action=' + action
              method = 'POST'
          try:
              with urllib.request.urlopen(urllib.request.Request(url, method=method), timeout=10) as response:
                  print(response.read().decode())
          except urllib.error.HTTPError as error:
              if action == 'status' and error.code == 404:
                  print('{"version":0}')
              else:
                  raise
          PYTHON
        PY
        ]
      }
    }]
  })
}

resource "aws_iam_role" "controller" {
  name = var.name
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "controller" {
  role = aws_iam_role.controller.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["autoscaling:DescribeAutoScalingGroups", "cloudwatch:GetMetricStatistics", "ssm:GetCommandInvocation"], Resource = "*" },
      { Effect = "Allow", Action = "autoscaling:TerminateInstanceInAutoScalingGroup", Resource = var.asg_arn },
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"], Resource = aws_dynamodb_table.state.arn },
      { Effect = "Allow", Action = "ssm:SendCommand", Resource = aws_ssm_document.retirement.arn },
      {
        Effect    = "Allow", Action = "ssm:SendCommand",
        Resource  = "${local.arn_prefix}:ec2:${local.region}:${local.account}:instance/*",
        Condition = { StringEquals = { "ssm:resourceTag/Name" = var.asg_name } }
      },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.controller.arn}:*" }
    ]
  })
}

resource "aws_cloudwatch_log_group" "controller" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = 30
}

data "archive_file" "controller" {
  type        = "zip"
  source_file = "${path.module}/controller.py"
  output_path = "${path.root}/.terraform/${var.name}.zip"
}

resource "aws_lambda_function" "controller" {
  function_name                  = var.name
  role                           = aws_iam_role.controller.arn
  runtime                        = "python3.13"
  handler                        = "controller.handler"
  filename                       = data.archive_file.controller.output_path
  source_code_hash               = data.archive_file.controller.output_base64sha256
  timeout                        = 60
  reserved_concurrent_executions = 1
  environment {
    variables = {
      ASG_NAME      = var.asg_name
      STATE_TABLE   = aws_dynamodb_table.state.name
      SSM_DOCUMENT  = aws_ssm_document.retirement.name
      MINIMUM_NODES = tostring(var.minimum_nodes)
      DRY_RUN       = tostring(var.dry_run)
    }
  }
  depends_on = [aws_iam_role_policy.controller]
}

resource "aws_cloudwatch_event_rule" "tick" {
  name                = var.name
  schedule_expression = "rate(1 minute)"
}
resource "aws_cloudwatch_event_target" "tick" {
  rule = aws_cloudwatch_event_rule.tick.name
  arn  = aws_lambda_function.controller.arn
}
resource "aws_lambda_permission" "tick" {
  statement_id  = "ScheduledRetirement"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.controller.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.tick.arn
}
resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "${var.name}-errors"
  alarm_description   = "Scale-in is blocked; inspect the controller logs. Never bypass a missing durability proof."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.controller.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

output "configuration" {
  value = {
    dry_run                = var.dry_run
    minimum_nodes          = var.minimum_nodes
    concurrent_retirements = aws_lambda_function.controller.reserved_concurrent_executions
    document               = aws_ssm_document.retirement.name
  }
}
