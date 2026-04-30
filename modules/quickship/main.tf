locals {
  resource_name = "${var.name_prefix}-${var.app_name}"

  subdomain = coalesce(var.subdomain, var.app_name)
  fqdn      = "${local.subdomain}.${data.cloudflare_zone.apex.name}"

  function_url_host = regex("https?://([^/]+)", module.lambda.lambda_function_url)[0]

  email_principals  = [for p in var.allowed_principals : p if !startswith(p, "*@")]
  domain_principals = [for p in var.allowed_principals : trimprefix(p, "*@") if startswith(p, "*@")]

  # Per-developer tags. The developer module's IAM user is tagged with
  # `quickship-username = <name>`; this app's resources get one
  # `quickship:dev:<name> = "1"` tag per developer in `var.developers`.
  # The dev's single managed policy grants per-app access via the
  # condition `aws:ResourceTag/quickship:dev:${aws:PrincipalTag/quickship-username} = 1`,
  # so adding/removing a dev from this list is the only thing needed
  # — no per-app managed policy proliferation, no IAM 10-policy cap.
  developer_tags = { for d in var.developers : "quickship:dev:${d}" => "1" }

  tags = merge(
    {
      "tinyapp:name"     = var.app_name
      "tinyapp:platform" = "v1"
      "tinyapp:managed"  = "true"
      "tinyapp:scope"    = "app"
    },
    local.developer_tags,
    var.tags,
  )
}

# Lambda function + execution role + log group + Function URL.
# Function URL has auth_type = AWS_IAM; only the per-app CloudFront
# distribution (via OAC SigV4 signing) is allowed to invoke. Direct hits
# to the lambda-url.* URL get 403 from AWS IAM.
module "lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 8.0"

  function_name = local.resource_name
  description   = "quickship ${var.app_name}"

  handler       = "handler.handler"
  runtime       = var.runtime
  architectures = ["arm64"]

  source_path = "${path.module}/placeholder"

  memory_size = var.memory_mb
  timeout     = var.timeout_seconds

  environment_variables = merge(
    # Always-present env var keeps the Lambda's `environment` block stable
    # across applies — terraform-aws-modules/lambda emits the block only when
    # env vars exist, and toggling block count trips the AWS provider.
    {
      TINYAPP_NAME = var.app_name
    },
    var.environment,
    var.database_enabled ? { DATABASE_URL = local.database_url } : {},
    local.capability_env_vars,
    local.secret_env_vars,
  )

  cloudwatch_logs_retention_in_days = var.log_retention_days

  create_lambda_function_url = true
  authorization_type         = "AWS_IAM"

  role_name = "${local.resource_name}-lambda"

  # When the per-app pipeline is on, CodeBuild owns the Lambda's code; TF
  # only owns the function shell. Ignoring source_code_hash + last_modified
  # keeps `terraform plan` clean across pipeline-driven code updates.
  ignore_source_code_hash = var.pipeline_enabled

  tags = local.tags
}
