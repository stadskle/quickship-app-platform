# CodeConnections — the service formerly known as CodeStar Connections.
#
# AWS rebranded this in 2024 when CodeStar (the project/dashboard service) was
# deprecated. The connection resource itself was unaffected; it's still the
# supported way to authorize CodePipeline against external git providers
# (GitHub, GitLab, Bitbucket, etc.).
#
# Connections are created in PENDING state. After first apply, finalize the
# OAuth handshake once per provider in the AWS Console:
#   Developer Tools → Settings → Connections → click the connection → "Update pending connection".
#
# Once authorized, the connection ARN is reusable across every per-app
# pipeline that gets provisioned in later steps.

resource "aws_codeconnections_connection" "git" {
  for_each = var.git_connection_providers

  name          = "${var.name_prefix}-${lower(each.value)}"
  provider_type = each.value

  tags = local.common_tags
}
