# Per-app secrets.
#
# Workflow (two applies on first secret, one on rotation):
#   1. Operator adds a name to `secret_names` and applies. TF creates an
#      SSM SecureString placeholder with value "REPLACE_ME". The Lambda
#      env var is set to that placeholder so the app deploys but the
#      helper raises a clear error if used.
#   2. Operator sets the real value out-of-band:
#        aws ssm put-parameter \
#          --name /<name_prefix>/apps/<app_name>/<secret_name> \
#          --value 'real-value' --type SecureString --overwrite \
#          --region <region>
#      (or the equivalent in the AWS console).
#   3. Re-apply. TF reads the new SSM value and updates the Lambda env.
#
# `lifecycle.ignore_changes = [value]` on the placeholder means TF never
# tries to overwrite an operator-set value with "REPLACE_ME" on subsequent
# applies. The companion `data.aws_ssm_parameter` block (with_decryption)
# is the source the env-var merge actually reads from in main.tf.
#
# IAM read on /<name_prefix>/apps/<app_name>/* lives in capabilities.tf
# (always-on `ssm_secrets` role policy). The wildcard is intentional —
# tightening to per-name ARNs would force an IAM policy change every
# time a secret is added, with no real security gain (it's the app's
# own namespace either way).

locals {
  secret_path_prefix = "/${var.name_prefix}/apps/${var.app_name}"
}

resource "aws_ssm_parameter" "secret" {
  for_each = toset(var.secret_names)

  name        = "${local.secret_path_prefix}/${each.value}"
  description = "Per-app secret '${each.value}' for ${var.app_name}. Placeholder created by Terraform; real value set out-of-band by operator."
  type        = "SecureString"
  value       = "REPLACE_ME"
  tags        = local.tags

  lifecycle {
    ignore_changes = [value]
  }
}

data "aws_ssm_parameter" "secret" {
  for_each = toset(var.secret_names)

  name            = aws_ssm_parameter.secret[each.value].name
  with_decryption = true
}

locals {
  secret_env_vars = {
    for name in var.secret_names :
    upper(name) => data.aws_ssm_parameter.secret[name].value
  }
}
