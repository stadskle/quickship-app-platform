# Read platform-level config from SSM. Bootstrap publishes everything per-app
# modules need to "Platform Facts" SSM parameters under /<prefix>/_platform/*;
# this module reads from there so app repos don't need to thread bootstrap
# outputs by hand.

# Cloudflare zone — needed for DNS records and Access app domain.
data "aws_ssm_parameter" "cf_zone_id" {
  name = "/${var.name_prefix}/cloudflare/zone_id"
}

data "aws_ssm_parameter" "cf_account_id" {
  name = "/${var.name_prefix}/cloudflare/account_id"
}

data "cloudflare_zone" "apex" {
  zone_id = data.aws_ssm_parameter.cf_zone_id.value
}

# AWS context.
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Platform facts published by bootstrap. Always present.
data "aws_ssm_parameter" "platform_waf_web_acl_arn" {
  name = "/${var.name_prefix}/_platform/waf_web_acl_arn"
}

# Conditional: read only when the capability is enabled. If the bootstrap
# didn't publish the parameter (e.g., bootstrap.email_enabled = false but app
# requests email_enabled = true), the data source fails with a clear error.
data "aws_ssm_parameter" "platform_neon_project_id" {
  count = var.database_enabled ? 1 : 0
  name  = "/${var.name_prefix}/_platform/neon_project_id"
}

data "aws_ssm_parameter" "platform_neon_default_branch_id" {
  count = var.database_enabled ? 1 : 0
  name  = "/${var.name_prefix}/_platform/neon_default_branch_id"
}

data "aws_ssm_parameter" "platform_neon_pooler_host" {
  count = var.database_enabled ? 1 : 0
  name  = "/${var.name_prefix}/_platform/neon_pooler_host"
}

data "aws_ssm_parameter" "platform_bedrock_model_arns" {
  count = var.ai_models_enabled ? 1 : 0
  name  = "/${var.name_prefix}/_platform/bedrock_model_arns"
}

data "aws_ssm_parameter" "platform_ses_sender_domain" {
  count = var.email_enabled ? 1 : 0
  name  = "/${var.name_prefix}/_platform/ses_sender_domain"
}

data "aws_ssm_parameter" "platform_ses_sender_identity_arn" {
  count = var.email_enabled ? 1 : 0
  name  = "/${var.name_prefix}/_platform/ses_sender_identity_arn"
}

# Pipeline-related platform facts. Only read when the per-app pipeline is on.
data "aws_ssm_parameter" "platform_pipeline_artifact_bucket" {
  count = var.pipeline_enabled ? 1 : 0
  name  = "/${var.name_prefix}/_platform/pipeline_artifact_bucket"
}

# Enumerate every CodeConnection bootstrap published. The per-app pipeline
# expects exactly one (single-provider deployments are the only supported
# shape today). Pipeline.tf asserts on this.
data "aws_ssm_parameters_by_path" "platform_git_connections" {
  count = var.pipeline_enabled ? 1 : 0
  path  = "/${var.name_prefix}/_platform/git_connection_arn"
}

# Orchestrator handles. The pipeline's CodeBuild calls into the orchestrator
# at the start of every build to run terraform — this gives "git push does
# everything" UX, and incidentally catches any console-edit drift.
data "aws_ssm_parameter" "platform_orchestrator_arn" {
  count = var.pipeline_enabled ? 1 : 0
  name  = "/${var.name_prefix}/_platform/orchestrator_arn"
}

data "aws_ssm_parameter" "platform_orchestrator_project" {
  count = var.pipeline_enabled ? 1 : 0
  name  = "/${var.name_prefix}/_platform/orchestrator_project"
}

data "aws_ssm_parameter" "platform_orchestrator_input_bucket" {
  count = var.pipeline_enabled ? 1 : 0
  name  = "/${var.name_prefix}/_platform/orchestrator_input_bucket"
}
