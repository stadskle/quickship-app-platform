# Platform-level credentials for the Cloudflare and Neon Terraform providers.
#
# Parameters are created with placeholder values. Operator fills in the real
# values via AWS Console (or `aws ssm put-parameter --overwrite`) after first
# apply. The lifecycle block on each SecureString prevents Terraform from
# fighting those manual updates.
#
# The quickship module reads these via `data "aws_ssm_parameter"` and either
# feeds them into the Cloudflare/Neon providers (operator-side) or into the
# Lambda env (runtime-side, only where appropriate).

locals {
  ssm_root = "/${var.name_prefix}"
}

resource "aws_ssm_parameter" "cloudflare_api_token" {
  name        = "${local.ssm_root}/cloudflare/api_token"
  description = "Cloudflare API token with Zone + Access edit scopes. Operator-set."
  type        = "SecureString"
  value       = "REPLACE_ME"
  tags        = local.common_tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "cloudflare_account_id" {
  name        = "${local.ssm_root}/cloudflare/account_id"
  description = "Cloudflare account ID hosting the quickship zone."
  type        = "String"
  value       = "REPLACE_ME"
  tags        = local.common_tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "cloudflare_zone_id" {
  name        = "${local.ssm_root}/cloudflare/zone_id"
  description = "Cloudflare zone ID where quickship DNS records and Access apps are created."
  type        = "String"
  value       = "REPLACE_ME"
  tags        = local.common_tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "neon_api_key" {
  name        = "${local.ssm_root}/neon/api_key"
  description = "Neon API key for project/branch creation. Operator-set."
  type        = "SecureString"
  value       = "REPLACE_ME"
  tags        = local.common_tags

  lifecycle {
    ignore_changes = [value]
  }
}
