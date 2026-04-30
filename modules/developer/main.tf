# Developer access — minimal-surface IAM user.
#
# Terraform creates ONLY the IAM user. Per-app permissions are attached as
# managed policies by quickship modules that name this developer in their
# `developers` input — the user gains/loses permissions as you add/remove
# them from app `developers` lists, with no re-onboarding.
#
# Access keys are NOT created in Terraform (deliberately — keeps secrets
# out of TF state). The platform admin runs after `terraform apply`:
#
#   aws iam create-access-key --user-name <prefix>-developer-<name>
#
# captures the AccessKeyId + SecretAccessKey from the CLI output, and
# hands them to the developer via a secure channel (1Password, Signal).
# The developer (or Claude on their behalf) configures locally with:
#
#   aws configure --profile <prefix>
#
# No console access, no MFA dance, no editing of ~/.aws/config.
#
# Trade-off accepted: the access key is long-lived with real per-app
# permissions until rotated. Mitigations: rotate periodically
# (`aws iam create-access-key` then `aws iam delete-access-key`), bake
# `gitleaks` into pre-commit hooks to catch accidental commits.

locals {
  resource_name = "${var.name_prefix}-developer-${var.name}"

  tags = merge(
    {
      "tinyapp:platform"  = "v1"
      "tinyapp:managed"   = "true"
      "tinyapp:scope"     = "developer"
      "tinyapp:developer" = var.name
    },
    var.tags,
  )
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_iam_user" "dev" {
  name = local.resource_name
  tags = local.tags
}

# Always-on read on the platform's PUBLIC fact namespace only. Developers
# need this for:
#   - bootstrap.sh in the app template (reads /<prefix>/_platform/source,
#     /_platform/orchestrator_project, /_platform/app_owners/<name>)
#   - /deploy invoking the orchestrator (reads orchestrator handles)
#
# Notably NOT granted: /<prefix>/cloudflare/*, /<prefix>/neon/* (platform
# secrets — only the orchestrator needs these for terraform-provider auth).
# The developer never runs terraform apply locally, so no need.
#
# Per-app secrets at /<prefix>/apps/<app>/* are granted separately by each
# quickship module (developer_access.tf), scoped to the apps the dev is on.
resource "aws_iam_user_policy" "platform_read" {
  name = "platform-read"
  user = aws_iam_user.dev.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ReadPlatformFacts"
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath",
        "ssm:DescribeParameters",
      ]
      Resource = "arn:aws:ssm:*:*:parameter/${var.name_prefix}/_platform/*"
    }]
  })
}

# Orchestrator-invoke permissions. Developers don't have terraform-apply
# perms directly; instead they upload their app's working tree as a zip
# and call the orchestrator's CodeBuild project, which has admin-ish perms
# and runs the apply on their behalf.
data "aws_ssm_parameter" "orchestrator_arn" {
  name = "/${var.name_prefix}/_platform/orchestrator_arn"
}

data "aws_ssm_parameter" "orchestrator_input_bucket" {
  name = "/${var.name_prefix}/_platform/orchestrator_input_bucket"
}

data "aws_ssm_parameter" "orchestrator_log_group" {
  name = "/${var.name_prefix}/_platform/orchestrator_log_group"
}

resource "aws_iam_user_policy" "orchestrator_invoke" {
  name = "orchestrator-invoke"
  user = aws_iam_user.dev.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "UploadBuildPayload"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:AbortMultipartUpload",
        ]
        Resource = "arn:aws:s3:::${data.aws_ssm_parameter.orchestrator_input_bucket.value}/*"
      },
      {
        Sid    = "ListInputBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
        ]
        Resource = "arn:aws:s3:::${data.aws_ssm_parameter.orchestrator_input_bucket.value}"
      },
      {
        Sid    = "InvokeOrchestrator"
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds",
          "codebuild:BatchGetProjects",
        ]
        Resource = data.aws_ssm_parameter.orchestrator_arn.value
      },
      {
        Sid    = "ReadOrchestratorLogs"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogStreams",
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:StartLiveTail",
          "logs:StopLiveTail",
        ]
        Resource = [
          "arn:aws:logs:*:*:log-group:${data.aws_ssm_parameter.orchestrator_log_group.value}",
          "arn:aws:logs:*:*:log-group:${data.aws_ssm_parameter.orchestrator_log_group.value}:*",
        ]
      },
    ]
  })
}
