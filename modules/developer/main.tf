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

# Always-on read on the platform's SSM namespace. Developers need this for:
#   - bootstrap.sh in the app template (reads /<prefix>/_platform/source)
#   - `terraform apply` on per-app infra (Cloudflare + Neon providers
#     read their API tokens from /<prefix>/cloudflare/* and /<prefix>/neon/*;
#     the per-app module data-reads /<prefix>/_platform/* facts)
#
# Trade-off: a leaked developer access key reads the platform's Cloudflare
# API token and Neon API key. With those, an attacker can manipulate the
# platform's Cloudflare zone and Neon project — meaningful blast radius.
# Mitigations: rotation, gitleaks pre-commit, single-tenant trust model.
# If the platform grows past solo-dev / small-team, replace this with a
# narrower scoping or a dedicated platform-deployer role.
resource "aws_iam_user_policy" "platform_read" {
  name = "platform-read"
  user = aws_iam_user.dev.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ReadPlatformSSM"
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath",
        "ssm:DescribeParameters",
      ]
      Resource = "arn:aws:ssm:*:*:parameter/${var.name_prefix}/*"
    }]
  })
}
