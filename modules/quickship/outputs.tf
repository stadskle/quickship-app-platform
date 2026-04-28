output "function_name" {
  value       = module.lambda.lambda_function_name
  description = "Lambda function name."
}

output "function_arn" {
  value       = module.lambda.lambda_function_arn
  description = "Lambda function ARN."
}

output "function_url" {
  value       = module.lambda.lambda_function_url
  description = "Raw Lambda Function URL. auth_type = AWS_IAM — direct hits return 403; only the per-app CloudFront distribution can invoke."
}

output "role_arn" {
  value       = module.lambda.lambda_role_arn
  description = "Lambda execution role ARN. Tag-scoped IAM policies in Step 5+ attach here."
}

output "role_name" {
  value       = module.lambda.lambda_role_name
  description = "Lambda execution role name."
}

output "log_group_name" {
  value       = module.lambda.lambda_cloudwatch_log_group_name
  description = "CloudWatch log group for this app's Lambda."
}

output "tags" {
  value       = local.tags
  description = "Effective tag map applied to every resource the module creates."
}

output "fqdn" {
  value       = local.fqdn
  description = "Public FQDN where the app is reachable through Cloudflare Access (e.g. hello-world.apps.example.com)."
}

output "url" {
  value       = "https://${local.fqdn}"
  description = "Public URL fronted by Cloudflare Access."
}

output "cloudfront_distribution_id" {
  value       = aws_cloudfront_distribution.app.id
  description = "ID of the per-app CloudFront distribution."
}

output "cloudfront_domain_name" {
  value       = aws_cloudfront_distribution.app.domain_name
  description = "Default cloudfront.net domain. Direct hits get 403 from WAF."
}

output "pipeline_name" {
  value       = local.pipeline_enabled ? aws_codepipeline.app[0].name : null
  description = "Name of the per-app CodePipeline (null when pipeline_enabled = false)."
}

output "pipeline_console_url" {
  value       = local.pipeline_enabled ? "https://${data.aws_region.current.region}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${aws_codepipeline.app[0].name}/view?region=${data.aws_region.current.region}" : null
  description = "Direct link to this app's pipeline in the AWS console. Useful when telling the user where to watch a deploy."
}
