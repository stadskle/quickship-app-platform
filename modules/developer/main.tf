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

  # Principal tag the per-app access policy uses for resource-tag matching:
  # quickship-username matches the suffix of `quickship:dev:<name>` tags
  # on per-app resources.
  tags = merge(local.tags, {
    "quickship-username" = var.name
  })
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
# and runs the apply on their behalf. Handles come in as inputs (rather
# than read from SSM) so the consumer wires the bootstrap → developer
# dependency explicitly via the TF graph.
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
        Resource = "arn:aws:s3:::${var.orchestrator_input_bucket}/*"
      },
      {
        Sid    = "ListInputBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
        ]
        Resource = "arn:aws:s3:::${var.orchestrator_input_bucket}"
      },
      {
        Sid    = "InvokeOrchestrator"
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds",
          "codebuild:BatchGetProjects",
        ]
        Resource = var.orchestrator_arn
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
          "arn:aws:logs:*:*:log-group:${var.orchestrator_log_group}",
          "arn:aws:logs:*:*:log-group:${var.orchestrator_log_group}:*",
        ]
      },
    ]
  })
}

# Single managed policy granting per-app debug + local-dev access. Scoped
# via tag-based access control: every per-app resource is tagged
# `quickship:dev:<name> = "1"` for each developer in that app's
# `developers` list. The policy condition checks the dev's specific tag
# (e.g., `quickship:dev:ketil`) on every action.
#
# The dev's name is hard-coded into THIS dev's policy at terraform-time
# (`${var.name}` → "ketil"). We do NOT use the IAM policy variable
# `${aws:PrincipalTag/quickship-username}` here: AWS only documents
# policy-variable interpolation in condition VALUES, not condition KEYS,
# and empirically the variable-in-key pattern was being matched as a
# literal string at evaluation time, denying every action. Hard-coding
# is fine because each developer has their own copy of this policy.
#
# Net effect: ONE managed policy per developer, scoping to N apps via
# resource-tag matching. Replaces the previous "one managed policy per
# (app, dev)" pattern that hit the AWS 10-managed-policies-per-user cap
# at 10 apps. Tags-per-resource cap (50) effectively means up to 50
# developers per app.
#
# Logs Insights, CodeBuild logs, and Bedrock are exceptions — see
# comments inline.
resource "aws_iam_policy" "app_access" {
  name        = "${local.resource_name}-app-access"
  description = "Per-app debug + local-dev access for ${var.name}, scoped via resource tags."
  tags        = local.tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "Lambda"
          Effect = "Allow"
          Action = [
            "lambda:GetFunction",
            "lambda:GetFunctionConfiguration",
            "lambda:GetFunctionCodeSigningConfig",
            "lambda:ListVersionsByFunction",
            "lambda:InvokeFunction",
          ]
          Resource = "*"
          Condition = {
            StringEquals = {
              "aws:ResourceTag/quickship:dev:${var.name}" = "1"
            }
          }
        },
        {
          Sid    = "CloudWatchLogs"
          Effect = "Allow"
          Action = [
            "logs:DescribeLogStreams",
            "logs:GetLogEvents",
            "logs:FilterLogEvents",
            "logs:StartLiveTail",
            "logs:StopLiveTail",
          ]
          Resource = "*"
          Condition = {
            StringEquals = {
              "aws:ResourceTag/quickship:dev:${var.name}" = "1"
            }
          }
        },
        {
          # Account-wide list — log-group enumeration with no resource scope.
          # Tag conditions don't apply to this action; we accept the visibility.
          Sid      = "DescribeLogGroups"
          Effect   = "Allow"
          Action   = ["logs:DescribeLogGroups"]
          Resource = "*"
        },
        {
          # CloudWatch Logs Insights — the API requires Resource: "*" and
          # tag conditions don't reliably apply across StartQuery's
          # log-group selection. Granted unconditionally; the actual log
          # data accessed is still bound by what's tagged-and-allowed via
          # GetLogEvents/etc. above.
          Sid    = "CloudWatchLogsInsights"
          Effect = "Allow"
          Action = [
            "logs:StartQuery",
            "logs:StopQuery",
            "logs:GetQueryResults",
            "logs:GetLogGroupFields",
          ]
          Resource = "*"
        },
        {
          # CodeBuild log groups (`/aws/codebuild/<name_prefix>-*`) are auto-
          # created by CodeBuild on first run, untagged. The tag-based
          # CloudWatchLogs statement above can't match them, so we grant
          # read access here name-prefix-scoped instead. Lower precision
          # than the tag scheme but acceptable: CodeBuild logs are build
          # output (no runtime user data), and the prefix already isolates
          # other accounts/customers if any.
          Sid    = "CodeBuildLogsByName"
          Effect = "Allow"
          Action = [
            "logs:DescribeLogStreams",
            "logs:GetLogEvents",
            "logs:FilterLogEvents",
            "logs:StartLiveTail",
            "logs:StopLiveTail",
          ]
          Resource = [
            "arn:aws:logs:*:*:log-group:/aws/codebuild/${var.name_prefix}-*",
            "arn:aws:logs:*:*:log-group:/aws/codebuild/${var.name_prefix}-*:*",
          ]
        },
        {
          # EventBridge Scheduler GetSchedule / GetScheduleGroup — name-
          # prefix-scoped because `aws_scheduler_schedule` doesn't support
          # tagging in the AWS provider. Schedules are named
          # `<name_prefix>-<app>-<cron-name>`. Devs see schedule details
          # only for prefix-matched schedules; manual test-fire uses the
          # existing tag-conditioned `lambda:InvokeFunction` with the
          # `_quickship_cron` payload.
          Sid    = "EventBridgeSchedulerGetByName"
          Effect = "Allow"
          Action = [
            "scheduler:GetSchedule",
            "scheduler:GetScheduleGroup",
          ]
          Resource = [
            "arn:aws:scheduler:*:*:schedule/default/${var.name_prefix}-*",
            "arn:aws:scheduler:*:*:schedule-group/default",
          ]
        },
        {
          # ListSchedules / ListScheduleGroups don't accept resource-scoped
          # grants. Account-wide enumeration; same shape as DescribeLogGroups
          # / dynamodb:ListTables. Devs see schedule names across the
          # account but cannot read details unless prefix-matched.
          Sid      = "EventBridgeSchedulerListAccountWide"
          Effect   = "Allow"
          Action   = ["scheduler:ListSchedules", "scheduler:ListScheduleGroups"]
          Resource = "*"
        },
        {
          Sid    = "CodeBuild"
          Effect = "Allow"
          Action = [
            "codebuild:StartBuild",
            "codebuild:RetryBuild",
            "codebuild:StopBuild",
            "codebuild:BatchGetBuilds",
            "codebuild:BatchGetProjects",
            "codebuild:ListBuildsForProject",
          ]
          Resource = "*"
          Condition = {
            StringEquals = {
              "aws:ResourceTag/quickship:dev:${var.name}" = "1"
            }
          }
        },
        {
          # ListProjects is account-wide — same shape as DescribeLogGroups,
          # ListTables, ListSchedules. Names visible across the account;
          # project metadata via BatchGetProjects remains tag-bound.
          Sid      = "CodeBuildListAccountWide"
          Effect   = "Allow"
          Action   = ["codebuild:ListProjects"]
          Resource = "*"
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
          Resource = "*"
          Condition = {
            StringEquals = {
              "aws:ResourceTag/quickship:dev:${var.name}" = "1"
            }
          }
        },
        {
          Sid    = "S3Storage"
          Effect = "Allow"
          Action = [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:ListBucket",
          ]
          Resource = "*"
          Condition = {
            StringEquals = {
              "aws:ResourceTag/quickship:dev:${var.name}" = "1"
            }
          }
        },
        {
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
          Resource = "*"
          Condition = {
            StringEquals = {
              "aws:ResourceTag/quickship:dev:${var.name}" = "1"
            }
          }
        },
        {
          # Account-wide list — table enumeration with no resource scope.
          # Tag conditions don't apply to ListTables. Devs see table NAMES
          # across the account; actual table content is still bounded by
          # the tag-scoped DynamoDB statement above.
          Sid      = "DynamoDBList"
          Effect   = "Allow"
          Action   = ["dynamodb:ListTables"]
          Resource = "*"
        },
        {
          Sid    = "SSMSecrets"
          Effect = "Allow"
          Action = [
            "ssm:GetParameter",
            "ssm:GetParameters",
            "ssm:GetParametersByPath",
            "ssm:PutParameter",
          ]
          Resource = "*"
          Condition = {
            StringEquals = {
              "aws:ResourceTag/quickship:dev:${var.name}" = "1"
            }
          }
        },
      ],
      length(var.bedrock_model_arns) > 0 ? [{
        # Bedrock foundation models are AWS-managed and untaggable. Granted
        # directly to the platform's published models. Minor over-grant —
        # all developers can invoke regardless of which apps they're on.
        # Mitigation: Nova Lite is cheap; budget alerts in bootstrap catch
        # runaway costs.
        #
        # Both the legacy InvokeModel API and the newer Converse API are
        # granted, plus their streaming variants. `app.lib.ai` uses
        # Converse; some apps may call InvokeModel directly.
        Sid    = "Bedrock"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:Converse",
          "bedrock:ConverseStream",
        ]
        Resource = var.bedrock_model_arns
      }] : [],
      length(var.bedrock_model_arns) > 0 ? [{
        # Read-only Bedrock + Service Quotas access so a developer (or
        # Claude on their behalf) can self-diagnose throttling/availability
        # without console access. Without these, ThrottlingException
        # surfaces with no way to check whether it's the model quota, the
        # inference-profile quota, or a missing model-access grant.
        Sid    = "BedrockReadDiagnostics"
        Effect = "Allow"
        Action = [
          "bedrock:ListFoundationModels",
          "bedrock:GetFoundationModel",
          "bedrock:GetFoundationModelAvailability",
          "bedrock:ListInferenceProfiles",
          "bedrock:GetInferenceProfile",
          "bedrock:ListModelInvocationJobs",
          "bedrock:GetModelInvocationLoggingConfiguration",
          "service-quotas:ListServiceQuotas",
          "service-quotas:GetServiceQuota",
          "service-quotas:ListAWSDefaultServiceQuotas",
        ]
        Resource = ["*"]
      }] : [],
    )
  })
}

resource "aws_iam_user_policy_attachment" "app_access" {
  user       = aws_iam_user.dev.name
  policy_arn = aws_iam_policy.app_access.arn
}
