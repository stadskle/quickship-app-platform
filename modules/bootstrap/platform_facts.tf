# Platform facts published to SSM Parameter Store for cross-repo consumption.
#
# These are non-secret platform-level values that per-app modules (in
# separate app repos) need at apply time: WAF ARN, Neon project handles,
# Bedrock model ARNs, SES sender info. The quickship module reads them via
# `data.aws_ssm_parameter` rather than receiving them as inputs.
#
# This is the cross-repo glue. Outputs of the bootstrap module (in
# outputs.tf) remain useful for `terraform output` inspection in the
# bootstrap's own root, but the SSM parameters are the source of truth
# for downstream apps.

locals {
  facts_root = "${local.ssm_root}/_platform"
}

# Always present — every quickship uses these.

resource "aws_ssm_parameter" "fact_waf_web_acl_arn" {
  name        = "${local.facts_root}/waf_web_acl_arn"
  description = "Platform-shared WAFv2 WebACL ARN. Per-app CloudFront distributions reference this."
  type        = "String"
  value       = aws_wafv2_web_acl.tinyapp_origin.arn
  tags        = local.common_tags
}

# Source URL of the platform modules repo. Read by app bootstrap.sh at
# scaffold time so apps don't need to hardcode it. Stored as host/path
# (no protocol) since the consuming Terraform `source = "git::https://..."`
# adds the protocol prefix.
resource "aws_ssm_parameter" "fact_platform_source" {
  name        = "${local.facts_root}/source"
  description = "Host/path of the platform modules git repo (e.g. github.com/owner/repo). App bootstrap.sh substitutes this into infra/main.tf module source."
  type        = "String"
  value       = var.platform_source
  tags        = local.common_tags
}

# Orchestrator handles. App template's /deploy + /destroy slash commands
# read these to invoke the right project + tail the right log group.
resource "aws_ssm_parameter" "fact_orchestrator_project" {
  name        = "${local.facts_root}/orchestrator_project"
  description = "CodeBuild project name for the orchestrator. /deploy + /destroy invoke this via aws codebuild start-build."
  type        = "String"
  value       = aws_codebuild_project.orchestrator.name
  tags        = local.common_tags
}

resource "aws_ssm_parameter" "fact_orchestrator_arn" {
  name        = "${local.facts_root}/orchestrator_arn"
  description = "Orchestrator CodeBuild project ARN. Developer module grants codebuild:StartBuild on this."
  type        = "String"
  value       = aws_codebuild_project.orchestrator.arn
  tags        = local.common_tags
}

resource "aws_ssm_parameter" "fact_orchestrator_input_bucket" {
  name        = "${local.facts_root}/orchestrator_input_bucket"
  description = "S3 bucket where /deploy uploads the build payload (zip of the app dir) before invoking the orchestrator."
  type        = "String"
  value       = aws_s3_bucket.orchestrator_input.bucket
  tags        = local.common_tags
}

resource "aws_ssm_parameter" "fact_orchestrator_log_group" {
  name        = "${local.facts_root}/orchestrator_log_group"
  description = "CloudWatch log group for orchestrator builds. Devs tail this to watch /deploy progress."
  type        = "String"
  value       = aws_cloudwatch_log_group.orchestrator.name
  tags        = local.common_tags
}

resource "aws_ssm_parameter" "fact_bedrock_model_arns" {
  name        = "${local.facts_root}/bedrock_model_arns"
  description = "Comma-separated Bedrock foundation-model ARNs that apps with `ai_models_enabled = true` may invoke."
  type        = "StringList"
  value       = join(",", [for m in var.bedrock_models : "arn:aws:bedrock:${data.aws_region.current.region}::foundation-model/${m}"])
  tags        = local.common_tags
}

resource "aws_ssm_parameter" "fact_neon_project_id" {
  name        = "${local.facts_root}/neon_project_id"
  description = "ID of the platform-shared Neon project. Per-app modules create roles + databases inside this project."
  type        = "String"
  value       = neon_project.platform.id
  tags        = local.common_tags
}

resource "aws_ssm_parameter" "fact_neon_default_branch_id" {
  name        = "${local.facts_root}/neon_default_branch_id"
  description = "ID of the default branch on the platform Neon project."
  type        = "String"
  value       = neon_project.platform.default_branch_id
  tags        = local.common_tags
}

resource "aws_ssm_parameter" "fact_neon_pooler_host" {
  name        = "${local.facts_root}/neon_pooler_host"
  description = "Pooler endpoint hostname for the platform Neon project."
  type        = "String"
  value       = neon_project.platform.database_host_pooler
  tags        = local.common_tags
}

# Conditional — only when bootstrap.email_enabled = true.

resource "aws_ssm_parameter" "fact_ses_sender_domain" {
  count = var.email_enabled ? 1 : 0

  name        = "${local.facts_root}/ses_sender_domain"
  description = "Verified SES sender domain. Apps send from <anything>@<this_domain>."
  type        = "String"
  value       = data.cloudflare_zone.apex[0].name
  tags        = local.common_tags
}

resource "aws_ssm_parameter" "fact_ses_sender_identity_arn" {
  count = var.email_enabled ? 1 : 0

  name        = "${local.facts_root}/ses_sender_identity_arn"
  description = "Platform-shared SES sender identity ARN. Per-app modules grant ses:SendEmail on this when `email_enabled = true`."
  type        = "String"
  value       = aws_sesv2_email_identity.platform[0].arn
  tags        = local.common_tags
}

# CodePipeline artifact bucket — per-app pipelines write build outputs here.
resource "aws_ssm_parameter" "fact_pipeline_artifact_bucket" {
  name        = "${local.facts_root}/pipeline_artifact_bucket"
  description = "S3 bucket name where per-app CodePipeline build artifacts land."
  type        = "String"
  value       = aws_s3_bucket.pipeline_artifacts.id
  tags        = local.common_tags
}

# CodeConnections ARN per provider — per-app pipelines pick the right one
# via `git_provider` input. Lower-cased provider name as the SSM key suffix.
resource "aws_ssm_parameter" "fact_git_connection_arn" {
  for_each = var.git_connection_providers

  name        = "${local.facts_root}/git_connection_arn/${lower(each.value)}"
  description = "CodeConnections ARN for git provider ${each.value}. Per-app pipelines reference this from their source stage."
  type        = "String"
  value       = aws_codeconnections_connection.git[each.value].arn
  tags        = local.common_tags
}
