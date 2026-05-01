# Per-app CI/CD: CodePipeline V2 + CodeBuild.
#
#   GitHub push → CodePipeline source (CodeConnection)
#                 → CodeBuild (build + zip + lambda update-function-code)
#                 → done.
#
# No CodeDeploy. The build step calls `aws lambda update-function-code`
# directly — blue/green via aliases is overkill for this stack. If we ever
# need staged rollouts, we add a deploy stage; today, fast simple wins.
#
# 0-drift contract: `ignore_source_code_hash = true` on the lambda module
# call (in main.tf) so Terraform stops fighting the pipeline-deployed code.
# After the first pipeline run, `terraform plan` is clean.
#
# Artifact bucket is platform-shared (one bucket, namespaced per app under
# apps/<app_name>/). Bootstrap owns the bucket and lifecycle; this module
# scopes IAM to its own prefix.

locals {
  pipeline_enabled    = var.pipeline_enabled
  pipeline_name       = local.resource_name
  artifact_bucket     = local.pipeline_enabled ? data.aws_ssm_parameter.platform_pipeline_artifact_bucket[0].value : null
  artifact_key_prefix = "apps/${var.app_name}"

  git_connection_arns = local.pipeline_enabled ? data.aws_ssm_parameters_by_path.platform_git_connections[0].values : []
}

# ---------- CodeBuild role -------------------------------------------------

resource "aws_iam_role" "codebuild" {
  count = local.pipeline_enabled ? 1 : 0

  name = "${local.resource_name}-codebuild"
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  count = local.pipeline_enabled ? 1 : 0

  name = "codebuild"
  role = aws_iam_role.codebuild[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${local.resource_name}*"
      },
      {
        Sid    = "ArtifactBucket"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:aws:s3:::${local.artifact_bucket}",
          "arn:aws:s3:::${local.artifact_bucket}/${local.artifact_key_prefix}/*",
        ]
      },
      {
        Sid    = "DeployLambda"
        Effect = "Allow"
        Action = [
          "lambda:UpdateFunctionCode",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
        ]
        Resource = module.lambda.lambda_function_arn
      },
      # Read the app's REPO_URL (= what app_owners stored on first apply) and
      # the orchestrator handles, so the buildspec can stage and trigger an
      # apply on every push.
      {
        Sid    = "ReadOrchestratorHandles"
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = [
          "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.name_prefix}/_platform/orchestrator_*",
          "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.name_prefix}/_platform/app_owners/${var.app_name}",
        ]
      },
      # Stage the source zip into the orchestrator's input bucket.
      {
        Sid    = "WriteOrchestratorInput"
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = "arn:aws:s3:::${data.aws_ssm_parameter.platform_orchestrator_input_bucket[0].value}/*"
      },
      # Trigger the orchestrator and poll until terminal.
      {
        Sid    = "InvokeOrchestrator"
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds",
        ]
        Resource = data.aws_ssm_parameter.platform_orchestrator_arn[0].value
      },
    ]
  })
}

resource "aws_codebuild_project" "build" {
  count = local.pipeline_enabled ? 1 : 0

  name         = local.resource_name
  description  = "Build and deploy ${var.app_name} (Lambda code update)."
  service_role = aws_iam_role.codebuild[0].arn
  tags         = local.tags

  # arm64 build runner — matches Lambda Graviton, so wheels installed here
  # (psycopg, cryptography) load correctly when packed into the Lambda zip.
  environment {
    type            = "ARM_CONTAINER"
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux2-aarch64-standard:3.0"
    privileged_mode = false

    environment_variable {
      name  = "LAMBDA_FUNCTION_NAME"
      value = module.lambda.lambda_function_name
    }
    environment_variable {
      name  = "AWS_REGION"
      value = data.aws_region.current.region
    }
    environment_variable {
      name  = "PYTHON_RUNTIME"
      value = var.runtime
    }

    # Orchestrator handles, used by buildspec's pre_build phase to run
    # terraform on every push (idempotent — fast no-op if no infra change).
    environment_variable {
      name  = "ORCHESTRATOR_PROJECT"
      value = data.aws_ssm_parameter.platform_orchestrator_project[0].value
    }
    environment_variable {
      name  = "ORCHESTRATOR_INPUT_BUCKET"
      value = data.aws_ssm_parameter.platform_orchestrator_input_bucket[0].value
    }
    environment_variable {
      name  = "PLATFORM_PREFIX"
      value = var.name_prefix
    }
    environment_variable {
      name  = "APP_NAME"
      value = var.app_name
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  logs_config {
    cloudwatch_logs {
      group_name = "/aws/codebuild/${local.resource_name}"
    }
  }
}

# ---------- CodePipeline role ---------------------------------------------

resource "aws_iam_role" "codepipeline" {
  count = local.pipeline_enabled ? 1 : 0

  name = "${local.resource_name}-codepipeline"
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codepipeline" {
  count = local.pipeline_enabled ? 1 : 0

  name = "codepipeline"
  role = aws_iam_role.codepipeline[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "UseConnection"
        Effect   = "Allow"
        Action   = "codestar-connections:UseConnection"
        Resource = local.git_connection_arns[0]
      },
      {
        Sid    = "ArtifactBucket"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:GetBucketVersioning",
        ]
        Resource = [
          "arn:aws:s3:::${local.artifact_bucket}",
          "arn:aws:s3:::${local.artifact_bucket}/${local.artifact_key_prefix}/*",
        ]
      },
      {
        Sid    = "InvokeBuild"
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds",
          "codebuild:StopBuild",
        ]
        Resource = aws_codebuild_project.build[0].arn
      },
    ]
  })
}

# ---------- CodePipeline ---------------------------------------------------

resource "aws_codepipeline" "app" {
  count = local.pipeline_enabled ? 1 : 0

  name           = local.pipeline_name
  pipeline_type  = "V2"
  role_arn       = aws_iam_role.codepipeline[0].arn
  execution_mode = "QUEUED"
  tags           = local.tags

  lifecycle {
    precondition {
      condition     = length(local.git_connection_arns) > 0
      error_message = "No CodeConnection found at /${var.name_prefix}/_platform/git_connection_arn/*. Add a provider to `git_connection_providers` in bootstrap, apply, and finalize the connection in the AWS console."
    }
    precondition {
      condition     = length(local.git_connection_arns) == 1
      error_message = "Multiple CodeConnections published; per-app provider selection is not supported. Reduce `git_connection_providers` in bootstrap to one entry."
    }
  }

  artifact_store {
    location = local.artifact_bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source"]

      configuration = {
        ConnectionArn        = local.git_connection_arns[0]
        FullRepositoryId     = var.git_repo
        BranchName           = var.git_branch
        OutputArtifactFormat = "CODE_ZIP"
        DetectChanges        = "true"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source"]
      output_artifacts = ["build"]

      configuration = {
        ProjectName = aws_codebuild_project.build[0].name
      }
    }
  }
}
