# Orchestrator: a single shared CodeBuild project that runs `terraform apply`
# (and `destroy`) for any per-app infra. All app deploys flow through this —
# the developer's IAM user has only `codebuild:StartBuild` on this project,
# never create/update on AWS resources directly.
#
# Why an S3 source instead of git: the orchestrator is git-host-agnostic.
# The developer's `/deploy` slash command zips their app's working tree,
# uploads it to the orchestrator's input bucket, then starts the build
# pointing at that zip. No PAT to provision, no source.location/auth
# coupling between CodeConnections and the actual repo URL.
#
# App-name collisions and ownership are tracked in SSM at
# /<prefix>/_platform/app_owners/<app_name>. The buildspec checks this on
# every apply (rejecting if claimed by a different repo URL) and clears
# the entry on a successful destroy.

locals {
  orchestrator_project_name = "${var.name_prefix}-orchestrator"
}

# ---- Input bucket for build payloads ---------------------------------------

resource "aws_s3_bucket" "orchestrator_input" {
  bucket        = "${var.name_prefix}-orchestrator-input-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = local.common_tags
}

resource "aws_s3_bucket_versioning" "orchestrator_input" {
  bucket = aws_s3_bucket.orchestrator_input.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "orchestrator_input" {
  bucket                  = aws_s3_bucket.orchestrator_input.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "orchestrator_input" {
  bucket = aws_s3_bucket.orchestrator_input.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "orchestrator_input" {
  depends_on = [aws_s3_bucket_versioning.orchestrator_input]
  bucket     = aws_s3_bucket.orchestrator_input.id

  rule {
    id     = "expire-old-build-inputs"
    status = "Enabled"

    filter {}

    expiration {
      days = 7
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# ---- IAM role for the orchestrator -----------------------------------------
#
# Admin-ish: PowerUserAccess for general AWS provisioning + a separate IAM
# inline policy for the IAM operations the per-app TF needs (creating
# Lambda execution roles, attaching managed policies, etc.).
#
# Tighten with tag conditions later if/when the threat model demands it.
# For now the trust boundary is "this is the only principal that runs
# terraform apply against per-app infra; the buildspec is fixed and
# version-controlled in this module."

resource "aws_iam_role" "orchestrator" {
  name = local.orchestrator_project_name
  tags = local.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "orchestrator_power_user" {
  role       = aws_iam_role.orchestrator.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# IAM permissions PowerUserAccess explicitly excludes. Per-app TF creates
# Lambda execution roles, app developer policies, etc.
resource "aws_iam_role_policy" "orchestrator_iam" {
  name = "iam"
  role = aws_iam_role.orchestrator.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ManageAppIAM"
      Effect = "Allow"
      Action = [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:UpdateRole",
        "iam:UpdateAssumeRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:CreatePolicy",
        "iam:DeletePolicy",
        "iam:GetPolicy",
        "iam:GetPolicyVersion",
        "iam:CreatePolicyVersion",
        "iam:DeletePolicyVersion",
        "iam:ListPolicyVersions",
        "iam:ListPolicies",
        "iam:AttachUserPolicy",
        "iam:DetachUserPolicy",
        "iam:PutUserPolicy",
        "iam:DeleteUserPolicy",
        "iam:GetUserPolicy",
        "iam:ListUserPolicies",
        "iam:ListAttachedUserPolicies",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:TagPolicy",
        "iam:UntagPolicy",
        "iam:TagUser",
        "iam:UntagUser",
        "iam:PassRole",
        "iam:CreateServiceLinkedRole",
      ]
      Resource = "*"
    }]
  })
}

# Read state from the platform tfstate bucket (per-app state lives under apps/).
resource "aws_iam_role_policy" "orchestrator_state" {
  name = "tfstate"
  role = aws_iam_role.orchestrator.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketVersioning",
        ]
        Resource = aws_s3_bucket.tfstate.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = "${aws_s3_bucket.tfstate.arn}/*"
      },
    ]
  })
}

# Read its own input bucket so it can fetch the build payload.
resource "aws_iam_role_policy" "orchestrator_input_read" {
  name = "input-bucket"
  role = aws_iam_role.orchestrator.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:ListBucket",
      ]
      Resource = [
        aws_s3_bucket.orchestrator_input.arn,
        "${aws_s3_bucket.orchestrator_input.arn}/*",
      ]
    }]
  })
}

# Manage the app_owners SSM namespace.
resource "aws_iam_role_policy" "orchestrator_app_owners" {
  name = "app-owners-registry"
  role = aws_iam_role.orchestrator.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:PutParameter",
        "ssm:DeleteParameter",
      ]
      Resource = "arn:aws:ssm:*:*:parameter/${var.name_prefix}/_platform/app_owners/*"
    }]
  })
}

# ---- Log group --------------------------------------------------------------

resource "aws_cloudwatch_log_group" "orchestrator" {
  name              = "/aws/codebuild/${local.orchestrator_project_name}"
  retention_in_days = 30
  tags              = local.common_tags
}

# ---- The buildspec ----------------------------------------------------------

locals {
  orchestrator_buildspec = <<-EOT
    version: 0.2
    #
    # Orchestrator buildspec. Runs `terraform apply` or `destroy` against the
    # per-app TF in the uploaded zip. Caller passes:
    #   - source-version: pointer to S3 zip
    #   - env REPO_URL:   git origin URL of the dev's app, recorded in
    #                     /<prefix>/_platform/app_owners/<app_name> for
    #                     ownership tracking
    #   - env MODE:       "apply" (default) or "destroy"
    #
    phases:
      install:
        commands:
          - echo "Installing Terraform..."
          - curl -sSLo /tmp/terraform.zip https://releases.hashicorp.com/terraform/1.15.0/terraform_1.15.0_linux_arm64.zip
          - unzip -q /tmp/terraform.zip -d /usr/local/bin/
          - terraform --version
          - echo "MODE=$${MODE:-apply}"
          - echo "REPO_URL=$REPO_URL"
      pre_build:
        commands:
          - test -d infra || { echo "ERROR no infra/ directory in upload"; exit 1; }
          - cd infra
          - APP_NAME=$(grep -E '^app_name\b' terraform.tfvars | head -1 | cut -d'"' -f2)
          - test -n "$APP_NAME" || { echo "ERROR could not parse app_name from terraform.tfvars"; exit 1; }
          - echo "APP_NAME=$APP_NAME"
          - test -n "$REPO_URL" || { echo "ERROR REPO_URL env var not set"; exit 1; }
          - |
            EXISTING=$(aws ssm get-parameter \
              --name "/${var.name_prefix}/_platform/app_owners/$APP_NAME" \
              --query Parameter.Value --output text 2>/dev/null || echo "")
            if [ -n "$EXISTING" ] && [ "$EXISTING" != "$REPO_URL" ]; then
              echo "ERROR: app_name '$APP_NAME' is already owned by repo $EXISTING"
              echo "       you are calling from $REPO_URL"
              echo "       Either pick a different app_name, or destroy the existing app first."
              exit 1
            fi
            echo "REGISTER=$([ -z "$EXISTING" ] && echo "yes" || echo "no")" > /tmp/orchestrator.env
            echo "MODE=$${MODE:-apply}" >> /tmp/orchestrator.env
      build:
        commands:
          - terraform init
          - . /tmp/orchestrator.env
          - |
            if [ "$MODE" = "destroy" ]; then
              terraform destroy -auto-approve
            else
              terraform apply -auto-approve
            fi
      post_build:
        commands:
          - . /tmp/orchestrator.env
          - |
            if [ "$CODEBUILD_BUILD_SUCCEEDING" = "1" ]; then
              if [ "$MODE" = "destroy" ]; then
                aws ssm delete-parameter \
                  --name "/${var.name_prefix}/_platform/app_owners/$APP_NAME" 2>/dev/null || true
                echo "✓ App '$APP_NAME' destroyed; registry entry cleared."
              elif [ "$REGISTER" = "yes" ]; then
                aws ssm put-parameter \
                  --name "/${var.name_prefix}/_platform/app_owners/$APP_NAME" \
                  --value "$REPO_URL" --type String
                echo "✓ Registered '$APP_NAME' to repo $REPO_URL"
              else
                echo "✓ Apply complete for '$APP_NAME' (already registered)."
              fi
            else
              echo "✗ Build failed; registry left untouched."
            fi
  EOT
}

# ---- The CodeBuild project --------------------------------------------------

resource "aws_codebuild_project" "orchestrator" {
  name         = local.orchestrator_project_name
  description  = "Runs terraform apply / destroy for any per-app TF. Single principal with admin-ish perms."
  service_role = aws_iam_role.orchestrator.arn
  tags         = local.common_tags

  build_timeout = 30 # minutes; CloudFront propagation alone can take a while

  environment {
    type            = "ARM_CONTAINER"
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux2-aarch64-standard:3.0"
    privileged_mode = false

    # Default mode; overridden per-build via --environment-variables-override.
    environment_variable {
      name  = "MODE"
      value = "apply"
    }

    environment_variable {
      name  = "REPO_URL"
      value = ""
    }
  }

  source {
    type     = "S3"
    location = "${aws_s3_bucket.orchestrator_input.bucket}/placeholder.zip"
    buildspec = local.orchestrator_buildspec
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.orchestrator.name
    }
  }
}
