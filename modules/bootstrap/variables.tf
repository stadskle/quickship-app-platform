variable "name_prefix" {
  type        = string
  description = "Prefix for platform-level resources (e.g. \"quickship\", \"acme-platform\"). Lowercase, alphanumeric and hyphens; 3-32 chars."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3-32 chars, lowercase letters/digits/hyphens, start with a letter, end alphanumeric."
  }
}

variable "platform_source" {
  type        = string
  description = "Full host/path of the platform modules git repo. NO protocol prefix; the consuming Terraform adds `git::https://`. Defaults to the canonical public repo; override only if you've forked it. Published to SSM so app bootstrap.sh can read it."
  default     = "github.com/stadskle/quickship-app-platform"

  validation {
    condition     = !can(regex("^https?://|^git@", var.platform_source)) && can(regex("^[a-z0-9.-]+/[^/]+/[^/]+", var.platform_source))
    error_message = "platform_source must be in 'host/owner/repo' form without a protocol (e.g. 'github.com/foo/bar'), not a full URL."
  }
}

variable "budget_monthly_usd" {
  type        = number
  description = "Monthly USD spend threshold for the account-level budget. Notifies at 80% actual and 100% forecasted."
  default     = 200

  validation {
    condition     = var.budget_monthly_usd > 0
    error_message = "budget_monthly_usd must be positive."
  }
}

variable "budget_alert_emails" {
  type        = list(string)
  description = "Email addresses notified when the account-level budget threshold is reached."

  validation {
    condition     = length(var.budget_alert_emails) > 0
    error_message = "Provide at least one budget alert email."
  }
}

variable "tags" {
  type        = map(string)
  description = "Extra tags applied to all bootstrap-created resources, merged on top of the platform tags."
  default     = {}
}

variable "git_connection_providers" {
  type        = set(string)
  description = "Git providers to create CodeStar Connections for. Each connection is created in PENDING state — finalize OAuth in AWS Console once."
  default     = []

  validation {
    condition = alltrue([
      for p in var.git_connection_providers :
      contains(["GitHub", "GitHubEnterpriseServer", "GitLab", "GitLabSelfManaged", "Bitbucket"], p)
    ])
    error_message = "Each provider must be one of: GitHub, GitHubEnterpriseServer, GitLab, GitLabSelfManaged, Bitbucket."
  }
}

variable "neon_region" {
  type        = string
  description = "Neon region identifier for the platform-shared project. Default colocates with the Lambda region for low latency."
  default     = "aws-eu-central-1"
}

variable "neon_pg_version" {
  type        = number
  description = "Postgres major version for the platform-shared Neon project."
  default     = 17
}

variable "bedrock_models" {
  type        = list(string)
  description = "Bedrock foundation-model IDs that per-app IAM roles can invoke when `ai_models_enabled = true`. Models must be available in the consumer's AWS region. Default `amazon.nova-lite-v1:0` is one of the few models available in eu-central-1 (no Anthropic models are yet in Frankfurt)."
  default     = ["amazon.nova-lite-v1:0"]
}

variable "email_enabled" {
  type        = bool
  description = "Whether to provision an SES domain identity for outbound email on the platform's apex Cloudflare zone. SES starts in sandbox mode (only verified recipients receive); request production access via the AWS Console once needed."
  default     = false
}
