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
