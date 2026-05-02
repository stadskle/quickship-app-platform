variable "app_name" {
  type        = string
  description = "Identifier for this app. Lowercase, alphanumeric and hyphens, 3-32 chars. Used as the value of the tinyapp:name tag, the Lambda name suffix, the future subdomain, etc."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.app_name))
    error_message = "app_name must be 3-32 chars, lowercase letters/digits/hyphens, start with a letter, end alphanumeric."
  }
}

variable "name_prefix" {
  type        = string
  description = "Platform prefix; should match the bootstrap module's name_prefix. Used in resource names."
  default     = "quickship"
}

variable "memory_mb" {
  type        = number
  description = "Lambda function memory size in MB."
  default     = 256
}

variable "timeout_seconds" {
  type        = number
  description = "Lambda function timeout in seconds. Default 25 — generous enough for Bedrock calls, DB cold-start migrations, and a couple of dependent AWS-API hops, while still well below the Function URL hard cap (900s) and CloudFront's idle limit (60s default; raised here via origin_read_timeout if needed). Bump per-app via the consumer module's `timeout_seconds` input when an app legitimately needs longer (long Bedrock prompts, large data export)."
  default     = 25
}

variable "runtime" {
  type        = string
  description = "Lambda runtime. Default matches the platform stack."
  default     = "python3.12"
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention in days for this app's Lambda logs."
  default     = 30
}

variable "environment" {
  type        = map(string)
  description = "Environment variables passed to the Lambda."
  default     = {}
}

variable "tags" {
  type        = map(string)
  description = "Extra tags applied to all app resources, merged on top of the platform tags."
  default     = {}
}

variable "subdomain" {
  type        = string
  description = "Subdomain under the platform apex domain. Defaults to app_name. Final URL becomes <subdomain>.<platform_domain>."
  default     = null
}

# ---- Capabilities ----------------------------------------------------------
#
# All platform-level inputs (WAF ARN, Neon handles, Bedrock model ARNs, SES
# sender info) are read from SSM Parameter Store at apply time — bootstrap
# publishes them under `/<prefix>/_platform/*`. Per-app TF only needs to set
# these capability flags.

variable "database_enabled" {
  type        = bool
  description = "Whether to create a Postgres role + database for this app inside the platform-shared Neon project. true → Lambda gets DATABASE_URL; false → no database resources, no DATABASE_URL. No default — pick deliberately per app."
}

variable "storage_enabled" {
  type        = bool
  description = "Provision a per-app S3 bucket for file storage (env var STORAGE_BUCKET, IAM read/write/list)."
  default     = false
}

variable "dynamodb_tables" {
  type        = list(string)
  description = "DynamoDB tables to create for this app (PAY_PER_REQUEST, hash key `key`, TTL on `ttl`). Names are prefixed with the app name. Each table exposed as env var `KV_TABLE_<UPPER_NAME>`."
  default     = []
}

variable "email_enabled" {
  type        = bool
  description = "Grant the Lambda IAM permission to send via the platform's shared SES identity. Requires `email_enabled = true` on the bootstrap module."
  default     = false
}

variable "ai_models_enabled" {
  type        = bool
  description = "Grant the Lambda IAM permission to invoke the Bedrock foundation models the bootstrap publishes."
  default     = false
}

variable "developers" {
  type        = list(string)
  description = "Developer names (must match `name` on a `developer` module call elsewhere) who get debug/operate access to this app. The module attaches a managed policy to each named developer's role granting Lambda inspect/invoke, CloudWatch logs, CodeBuild + CodePipeline operations, and capability-mirrored access (S3/DynamoDB/Bedrock/SSM secrets) so local dev can exercise real AWS. Empty list = no developer access (lambda execution role unaffected either way)."
  default     = []

  validation {
    condition = alltrue([
      for n in var.developers :
      can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", n))
    ])
    error_message = "Each developer name must be 2-32 chars, lowercase letters/digits/hyphens, start with a letter, end alphanumeric (must match the `name` input on a `developer` module call)."
  }
}

variable "pipeline_enabled" {
  type        = bool
  description = "Provision a CodePipeline + CodeBuild that builds this app's repo and deploys to the Lambda. Requires `git_repo`. Default `true` — apps ship via the pipeline; set `false` only when you genuinely want manual `aws lambda update-function-code` deploys (e.g., debugging the module itself)."
  default     = true
}

variable "git_repo" {
  type        = string
  description = "Repo holding this app's source, in `owner/repo` form (GitHub) or `owner/group/.../repo` form (GitLab nested groups). NOT the full URL — paste only the path part. The repo must already exist. The platform's CodeConnection must be authorized for the top-level owner; otherwise the pipeline source action fails with `Repository not found`."
  default     = null

  validation {
    condition     = var.git_repo == null || can(regex("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$", var.git_repo))
    error_message = "git_repo must be 'owner/repo' (GitHub) or 'owner/group/.../repo' (GitLab nested groups). Not a URL, not just the repo name."
  }

  validation {
    condition     = !var.pipeline_enabled || var.git_repo != null
    error_message = "pipeline_enabled = true requires git_repo to be set (format: 'owner/repo'). To deploy without a pipeline, set pipeline_enabled = false."
  }
}

variable "git_branch" {
  type        = string
  description = "Branch that triggers builds. Default `main`. Override only if your repo's default branch is `master` or you ship from a different long-lived branch (e.g., a non-prod env tracking `test`)."
  default     = "main"
}

variable "pipeline_orchestrator_trigger" {
  type        = bool
  description = "When true (default), the pipeline triggers the platform orchestrator to run `terraform apply` before updating Lambda code on every push — so any change in `infra/` propagates without a separate verb. When false, the pipeline ONLY runs `aws lambda update-function-code` (no orchestrator hit). Set false for non-primary environments (test/staging) where infra is owned by the prod pipeline; otherwise the test branch's `terraform.tfvars` would race the prod branch's against shared tfstate."
  default     = true
}

variable "cron_schedules" {
  type = list(object({
    name       = string
    expression = string
  }))
  description = "EventBridge Scheduler entries that invoke the Lambda with payload {\"_quickship_cron\":\"<name>\"}. App code dispatches on that field via backend/app/cron.py. Expression is AWS schedule syntax: `cron(0 9 * * ? *)` (UTC) or `rate(1 hour)`. Function in app/cron.py must match the `name` exactly (lowercase letters/digits/underscores)."
  default     = []

  validation {
    condition = alltrue([
      for s in var.cron_schedules :
      can(regex("^[a-z][a-z0-9_]*$", s.name))
    ])
    error_message = "cron_schedules: each name must be lowercase letters/digits/underscores, starting with a letter."
  }
}

variable "secret_names" {
  type        = list(string)
  description = "Names of per-app secrets the app will read at runtime. Each becomes an SSM SecureString placeholder at /<prefix>/apps/<app>/<name>, and is injected into Lambda as env var <NAME_UPPERCASE>. Operators set the real value out-of-band (CLI/console) and re-apply to push it to Lambda. Names must be lowercase letters/digits/underscores."
  default     = []

  validation {
    condition = alltrue([
      for n in var.secret_names :
      can(regex("^[a-z][a-z0-9_]*$", n))
    ])
    error_message = "Each secret name must match ^[a-z][a-z0-9_]*$ (lowercase letters/digits/underscores, starting with a letter)."
  }
}

variable "allowed_principals" {
  type        = list(string)
  description = "Who can access this app via Cloudflare Access. Mix of explicit emails (e.g. \"alice@x.com\") and domain wildcards (e.g. \"*@company.com\"). Auto-classified."

  validation {
    condition = alltrue([
      for p in var.allowed_principals :
      can(regex("^(\\*@[^*@]+|[^*@]+@[^*@]+\\.[^*@]+)$", p))
    ])
    error_message = "Each entry must be either \"*@domain.tld\" or a full email like \"name@domain.tld\"."
  }
}
