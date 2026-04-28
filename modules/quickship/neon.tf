# Per-app Postgres on the platform-shared Neon project.
#
# Each quickship gets its own role + database inside the shared project.
# Compute and storage are shared (free tier: 191.9 hr/mo + 0.5 GB across
# all apps); data isolation is enforced at the Postgres level — the role
# owns only its own database, no cross-database CONNECT grants.
#
# Schema initialisation (the JSONB single-table) is the app's responsibility:
# the template's `app/lib/db.py` runs `CREATE TABLE IF NOT EXISTS records …`
# at module load. No operator dependency, no Postgres provider in TF, no
# psql required locally.
#
# DATABASE_URL is injected as a Lambda env var AND mirrored to SSM
# SecureString at /<prefix>/apps/<app>/database_url so operators can run
# `psql "$(aws ssm get-parameter --name … --with-decryption …)"` for ops.

resource "neon_role" "app" {
  count = var.database_enabled ? 1 : 0

  project_id = data.aws_ssm_parameter.platform_neon_project_id[0].value
  branch_id  = data.aws_ssm_parameter.platform_neon_default_branch_id[0].value
  name       = var.app_name
}

resource "neon_database" "app" {
  count = var.database_enabled ? 1 : 0

  project_id = data.aws_ssm_parameter.platform_neon_project_id[0].value
  branch_id  = data.aws_ssm_parameter.platform_neon_default_branch_id[0].value
  name       = var.app_name
  owner_name = neon_role.app[0].name
}

locals {
  database_url = var.database_enabled ? format(
    "postgresql://%s:%s@%s/%s?sslmode=require",
    neon_role.app[0].name,
    neon_role.app[0].password,
    data.aws_ssm_parameter.platform_neon_pooler_host[0].value,
    neon_database.app[0].name,
  ) : null
}

resource "aws_ssm_parameter" "database_url" {
  count = var.database_enabled ? 1 : 0

  name        = "/${var.name_prefix}/apps/${var.app_name}/database_url"
  description = "Postgres connection string for quickship ${var.app_name}. Pooler endpoint, sslmode=require. Mirrored to Lambda env var DATABASE_URL."
  type        = "SecureString"
  value       = local.database_url
  tags        = local.tags
}
