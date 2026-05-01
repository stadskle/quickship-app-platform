output "tfstate_bucket_name" {
  value       = aws_s3_bucket.tfstate.id
  description = "Name of the tfstate S3 bucket. Use in a backend \"s3\" block with use_lockfile = true."
}

output "tfstate_bucket_arn" {
  value       = aws_s3_bucket.tfstate.arn
  description = "ARN of the tfstate bucket."
}

output "account_id" {
  value       = data.aws_caller_identity.current.account_id
  description = "Account this bootstrap was applied in."
}

output "platform_tags" {
  value       = local.common_tags
  description = "Tags applied to all bootstrap resources. Useful for setting provider-level default_tags downstream."
}

output "ssm_secret_paths" {
  description = "SSM parameter paths for platform credentials. Fill in the real values via console after apply."
  value = {
    cloudflare_api_token  = aws_ssm_parameter.cloudflare_api_token.name
    cloudflare_account_id = aws_ssm_parameter.cloudflare_account_id.name
    cloudflare_zone_id    = aws_ssm_parameter.cloudflare_zone_id.name
    neon_api_key          = aws_ssm_parameter.neon_api_key.name
  }
}

output "ssm_secret_arns" {
  description = "ARNs of platform credential parameters. Use to scope IAM read policies in the quickship module."
  value = {
    cloudflare_api_token  = aws_ssm_parameter.cloudflare_api_token.arn
    cloudflare_account_id = aws_ssm_parameter.cloudflare_account_id.arn
    cloudflare_zone_id    = aws_ssm_parameter.cloudflare_zone_id.arn
    neon_api_key          = aws_ssm_parameter.neon_api_key.arn
  }
}

output "git_connection_arns" {
  description = "CodeConnections ARNs keyed by provider name. Finalize each connection in the AWS Console before use."
  value       = { for p, c in aws_codeconnections_connection.git : p => c.arn }
}

output "pipeline_artifact_bucket_name" {
  description = "S3 bucket holding per-app CodePipeline build artifacts. Per-app pipelines write to apps/<app>/ prefixes here."
  value       = aws_s3_bucket.pipeline_artifacts.id
}

output "origin_waf_web_acl_arn" {
  description = "ARN of the shared WAFv2 WebACL guarding quickship CloudFront distributions. Per-app modules attach this via web_acl_id on aws_cloudfront_distribution."
  value       = aws_wafv2_web_acl.tinyapp_origin.arn
}

output "origin_secret_ssm_name" {
  description = "SSM parameter name (SecureString) holding the shared origin secret. Reserved for inspection / rotation tooling — runtime code never reads it."
  value       = aws_ssm_parameter.origin_secret.name
}

output "origin_secret_ssm_arn" {
  description = "ARN of the origin-secret SSM parameter."
  value       = aws_ssm_parameter.origin_secret.arn
}

output "neon_project_id" {
  description = "ID of the platform-shared Neon project. Pass to per-app quickship modules."
  value       = neon_project.platform.id
}

output "neon_default_branch_id" {
  description = "ID of the default branch on the platform Neon project."
  value       = neon_project.platform.default_branch_id
}

output "neon_pooler_host" {
  description = "Pooler endpoint hostname for the platform Neon project. Used to construct per-app DATABASE_URLs."
  value       = neon_project.platform.database_host_pooler
}

output "bedrock_model_arns" {
  description = "Bedrock ARNs to grant InvokeModel on when `ai_models_enabled = true`. Includes the regional inference-profile ARN AND the foundation-model ARN with a region wildcard. The wildcard is required because cross-region inference profiles can route the invocation to the foundation model in any of several regions (e.g. `eu.` profiles route across eu-central-1 / eu-west-1 / eu-west-3 / eu-north-1, varying per model and as AWS adds routing regions). Foundation-model ARNs have no account ID and are AWS-managed, so the regional wildcard isn't a real isolation concern."
  value       = local.bedrock_model_arns
}

output "bedrock_inference_profile_ids" {
  description = "Regional inference-profile IDs (e.g. `eu.amazon.nova-lite-v1:0`) — what apps actually pass as model_id to Bedrock invoke. Mirrors `bedrock_models` with the regional prefix added."
  value       = [for m in var.bedrock_models : "${local.bedrock_geo_prefix == "" ? "" : "${local.bedrock_geo_prefix}."}${m}"]
}

output "ses_sender_domain" {
  description = "Verified SES sender domain (the apex Cloudflare zone). null when `email_enabled = false`. Apps send from `<anything>@<this_domain>`."
  value       = var.email_enabled ? data.cloudflare_zone.apex[0].name : null
}

output "ses_sender_identity_arn" {
  description = "SES sender identity ARN. Per-app modules grant ses:SendEmail on this ARN when `email_enabled = true`. null when bootstrap email is disabled."
  value       = var.email_enabled ? aws_sesv2_email_identity.platform[0].arn : null
}

# Orchestrator handles. Pass these to the `developer` module so it can grant
# invoke permissions to each developer's IAM user. Wiring as outputs (instead
# of having the developer module read SSM directly) creates an explicit graph
# dependency so the developer module's plan/apply can't run before bootstrap
# has created the orchestrator.
output "orchestrator_arn" {
  description = "ARN of the orchestrator CodeBuild project. Pass to the developer module."
  value       = aws_codebuild_project.orchestrator.arn
}

output "orchestrator_project_name" {
  description = "Name of the orchestrator CodeBuild project."
  value       = aws_codebuild_project.orchestrator.name
}

output "orchestrator_input_bucket" {
  description = "S3 bucket where /deploy uploads build payloads."
  value       = aws_s3_bucket.orchestrator_input.bucket
}

output "orchestrator_log_group" {
  description = "CloudWatch log group for orchestrator builds."
  value       = aws_cloudwatch_log_group.orchestrator.name
}
