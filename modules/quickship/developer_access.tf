# Per-app developer access.
#
# When `developers = ["alice", ...]`, this module assembles a managed IAM
# policy granting the developer everything they need to debug + operate
# this app, and attaches that policy to each developer's IAM user
# (`<name_prefix>-developer-<name>`, created by the `developer` module).
#
# Permissions split into two buckets:
#
#   1. ALWAYS granted (regardless of capability flags):
#      - Lambda: inspect + invoke this function (NOT UpdateFunctionCode —
#        that's the pipeline's job; devs shouldn't bypass CI).
#      - CloudWatch Logs: read + tail this Lambda's log group + this
#        CodeBuild's log group.
#      - CloudWatch Logs Insights: query (account-wide; the Insights API
#        requires "*" Resource — actual queries still bound by which log
#        group the dev points them at).
#      - CodeBuild + CodePipeline (only when pipeline_enabled): start /
#        retry / inspect this app's pipeline.
#
#   2. CAPABILITY-MIRRORED (lets `AWS_PROFILE=<prefix> docker compose up`
#      hit real AWS for end-to-end local dev):
#      - S3 storage RW (when storage_enabled).
#      - DynamoDB RW on this app's tables (when dynamodb_tables non-empty).
#      - Bedrock InvokeModel on platform models (when ai_models_enabled).
#      - SSM Get/Put on this app's secrets path (when secret_names
#        non-empty — Put is included so devs can populate secret values
#        per the documented workflow).
#
# Deliberately NOT granted:
#   - ses:SendEmail. The local email helper falls back to stderr; keep it
#     that way to avoid accidental real emails during development.
#   - lambda:UpdateFunctionCode. The pipeline owns deploys.

locals {
  developer_access_enabled = length(var.developers) > 0

  # Build the policy statements as a flat list, conditionally including
  # capability-specific blocks. Each statement is wrapped in a single-element
  # list so concat() can stitch them together cleanly.
  _stmt_lambda = [{
    Sid    = "Lambda"
    Effect = "Allow"
    Action = [
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:GetFunctionCodeSigningConfig",
      "lambda:ListVersionsByFunction",
      "lambda:InvokeFunction",
    ]
    Resource = module.lambda.lambda_function_arn
  }]

  _stmt_logs = [{
    Sid    = "CloudWatchLogs"
    Effect = "Allow"
    Action = [
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:StartLiveTail",
      "logs:StopLiveTail",
    ]
    Resource = [
      module.lambda.lambda_cloudwatch_log_group_arn,
      "${module.lambda.lambda_cloudwatch_log_group_arn}:*",
      "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${local.resource_name}",
      "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${local.resource_name}:*",
    ]
  }]

  _stmt_logs_insights = [{
    Sid    = "CloudWatchLogsInsights"
    Effect = "Allow"
    Action = [
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:GetQueryResults",
      "logs:GetLogGroupFields",
    ]
    Resource = "*"
  }]

  _stmt_pipeline = local.pipeline_enabled ? [
    {
      Sid    = "CodeBuild"
      Effect = "Allow"
      Action = [
        "codebuild:StartBuild",
        "codebuild:RetryBuild",
        "codebuild:StopBuild",
        "codebuild:BatchGetBuilds",
        "codebuild:ListBuildsForProject",
      ]
      Resource = aws_codebuild_project.build[0].arn
    },
    {
      Sid    = "CodePipeline"
      Effect = "Allow"
      Action = [
        "codepipeline:GetPipelineState",
        "codepipeline:GetPipelineExecution",
        "codepipeline:ListPipelineExecutions",
        "codepipeline:StartPipelineExecution",
      ]
      Resource = aws_codepipeline.app[0].arn
    },
  ] : []

  _stmt_storage = var.storage_enabled ? [{
    Sid    = "S3Storage"
    Effect = "Allow"
    Action = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    Resource = [
      aws_s3_bucket.storage[0].arn,
      "${aws_s3_bucket.storage[0].arn}/*",
    ]
  }] : []

  _stmt_dynamodb = length(var.dynamodb_tables) > 0 ? [{
    Sid    = "DynamoDB"
    Effect = "Allow"
    Action = [
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:GetItem",
      "dynamodb:BatchGetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:DescribeTable",
    ]
    Resource = [for t in aws_dynamodb_table.kv : t.arn]
  }] : []

  _stmt_bedrock = var.ai_models_enabled ? [{
    Sid      = "Bedrock"
    Effect   = "Allow"
    Action   = ["bedrock:InvokeModel"]
    Resource = split(",", data.aws_ssm_parameter.platform_bedrock_model_arns[0].value)
  }] : []

  _stmt_secrets = length(var.secret_names) > 0 ? [{
    Sid    = "SSMSecrets"
    Effect = "Allow"
    Action = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:PutParameter",
    ]
    Resource = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${local.secret_path_prefix}/*"
  }] : []

  developer_access_statements = concat(
    local._stmt_lambda,
    local._stmt_logs,
    local._stmt_logs_insights,
    local._stmt_pipeline,
    local._stmt_storage,
    local._stmt_dynamodb,
    local._stmt_bedrock,
    local._stmt_secrets,
  )
}

resource "aws_iam_policy" "developer_access" {
  count = local.developer_access_enabled ? 1 : 0

  name        = "${local.resource_name}-developer-access"
  description = "Per-app developer access for ${var.app_name}. Attached to developer roles named in var.developers."
  tags        = local.tags

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.developer_access_statements
  })
}

# Attach to each named developer's IAM user. The user name follows the
# convention from the `developer` module (`<name_prefix>-developer-<name>`).
# If the named developer doesn't exist, this fails at apply with a clear
# `NoSuchEntity` error pointing at the missing user.
resource "aws_iam_user_policy_attachment" "developer_access" {
  for_each = local.developer_access_enabled ? toset(var.developers) : toset([])

  user       = "${var.name_prefix}-developer-${each.value}"
  policy_arn = aws_iam_policy.developer_access[0].arn
}
