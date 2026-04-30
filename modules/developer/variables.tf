variable "name" {
  type        = string
  description = "Short identifier for the developer (e.g. 'alice', 'bob'). Used to build the IAM user name. Lowercase letters/digits/hyphens, 2-32 chars."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 2-32 chars, lowercase letters/digits/hyphens, start with a letter, end alphanumeric."
  }
}

variable "name_prefix" {
  type        = string
  description = "Platform prefix; should match the bootstrap module's name_prefix. Used in the IAM user name so resources are obviously platform-owned."
  default     = "quickship"
}

variable "tags" {
  type        = map(string)
  description = "Extra tags applied to the IAM user."
  default     = {}
}

# Orchestrator handles — pass module.<bootstrap>.orchestrator_*.
# These create an explicit graph dependency on the bootstrap module so this
# module's plan can't run before the orchestrator exists.
variable "orchestrator_arn" {
  type        = string
  description = "ARN of the orchestrator CodeBuild project. Pass `module.<bootstrap>.orchestrator_arn`."
}

variable "orchestrator_input_bucket" {
  type        = string
  description = "Name of the orchestrator's S3 input bucket. Pass `module.<bootstrap>.orchestrator_input_bucket`."
}

variable "orchestrator_log_group" {
  type        = string
  description = "Name of the orchestrator's CloudWatch log group. Pass `module.<bootstrap>.orchestrator_log_group`."
}

variable "bedrock_model_arns" {
  type        = list(string)
  description = "Bedrock foundation-model ARNs the developer can invoke (for local-dev AI helpers). Pass `module.<bootstrap>.bedrock_model_arns`. Bedrock model ARNs are AWS-managed and untaggable — granted directly rather than via the tag-based per-app scoping."
  default     = []
}
