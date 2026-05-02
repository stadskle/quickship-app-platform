# Scheduled jobs.
#
# Each entry in `var.cron_schedules` becomes:
#   - one EventBridge Scheduler resource (in the default group)
#   - tagged like every other per-app resource (developer access flows
#     through the same `quickship:dev:<name>` tags)
#   - target: this app's Lambda, payload `{"_quickship_cron": "<name>"}`
#   - retry policy: 3 attempts within 1h (EventBridge default-ish)
#
# A single shared `aws_iam_role` is created for the scheduler service to
# invoke the Lambda — only created when there's at least one schedule, so
# apps without scheduled jobs incur no extra IAM resources.

locals {
  has_schedules    = length(var.cron_schedules) > 0
  schedules_by_key = { for s in var.cron_schedules : s.name => s }
}

# IAM role assumed by EventBridge Scheduler when firing a schedule. Lambda's
# resource policy accepts this role (single grant on the function) so all
# schedules can invoke without per-schedule plumbing.
resource "aws_iam_role" "scheduler" {
  count = local.has_schedules ? 1 : 0

  name = "${local.resource_name}-scheduler"
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_invoke_lambda" {
  count = local.has_schedules ? 1 : 0

  name = "invoke-lambda"
  role = aws_iam_role.scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = module.lambda.lambda_function_arn
    }]
  })
}

resource "aws_scheduler_schedule" "cron" {
  for_each = local.schedules_by_key

  name       = "${local.resource_name}-${each.key}"
  group_name = "default"

  schedule_expression          = each.value.expression
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = module.lambda.lambda_function_arn
    role_arn = aws_iam_role.scheduler[0].arn

    input = jsonencode({
      _quickship_cron = each.key
    })

    retry_policy {
      maximum_retry_attempts       = 3
      maximum_event_age_in_seconds = 3600
    }
  }
}

# Note: aws_scheduler_schedule doesn't have a `tags` argument in the
# AWS provider's schema (as of v6.x). Developer access to schedules is
# scoped via name prefix instead — see the developer module's
# EventBridgeScheduler statement (granted on
# arn:aws:scheduler:*:*:schedule/default/<name_prefix>-*). Same shape as
# the CodeBuild logs name-prefix workaround.
