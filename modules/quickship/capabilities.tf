# Step 5 capabilities — opt-in per app.
#
# - storage   → S3 bucket (encrypted, public access blocked)
# - kv        → 0+ DynamoDB tables (PAY_PER_REQUEST, hash key "key")
# - email     → IAM grant on the platform-shared SES identity
# - ai_models → IAM grant on the platform-shared Bedrock model list
#
# Always-on for every app (no flag): IAM read on the per-app SSM secrets
# namespace at /<prefix>/apps/<app>/* — operators put per-app secrets there.

locals {
  dynamodb_table_full_names = {
    for short_name in var.dynamodb_tables :
    short_name => "${local.resource_name}-${short_name}"
  }

  dynamodb_env_vars = {
    for short_name, full_name in local.dynamodb_table_full_names :
    "KV_TABLE_${upper(replace(short_name, "-", "_"))}" => full_name
  }

  capability_env_vars = merge(
    var.storage_enabled ? { STORAGE_BUCKET = aws_s3_bucket.storage[0].id } : {},
    local.dynamodb_env_vars,
    var.email_enabled ? { EMAIL_SENDER_DOMAIN = data.aws_ssm_parameter.platform_ses_sender_domain[0].value } : {},
  )
}

# ---------- S3 storage ------------------------------------------------------

resource "aws_s3_bucket" "storage" {
  count = var.storage_enabled ? 1 : 0

  bucket = "${local.resource_name}-storage-${data.aws_caller_identity.current.account_id}"
  # Allow `terraform destroy` to delete the bucket even when it has objects.
  # Without this, BucketNotEmpty blocks destroy. Trade-off: makes accidental
  # destroys data-losing — that's fine for solo-dev quickship apps where the
  # explicit verb (`./scripts/destroy.sh`) requires typed-name confirmation
  # and the platform's stance is "capability disable = data loss".
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "storage" {
  count = var.storage_enabled ? 1 : 0

  bucket                  = aws_s3_bucket.storage[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "storage" {
  count = var.storage_enabled ? 1 : 0

  bucket = aws_s3_bucket.storage[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_iam_role_policy" "storage" {
  count = var.storage_enabled ? 1 : 0

  name = "storage"
  role = module.lambda.lambda_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
      ]
      Resource = [
        aws_s3_bucket.storage[0].arn,
        "${aws_s3_bucket.storage[0].arn}/*",
      ]
    }]
  })
}

# ---------- S3 storage: localdev twin ---------------------------------------
#
# Empty S3 buckets cost $0; provisioning a per-app `-localdev` twin gives
# `docker compose up` a real S3 to talk to (via the dev's AWS profile)
# instead of the host-disk fallback in storage.py. Real semantics, no
# prod-data risk, no localstack container.
#
# The Lambda execution role's IAM grant above only references the prod
# bucket — production code can never accidentally touch localdev. The
# developer's tag-based access policy covers BOTH because both buckets
# carry the same `quickship:dev:<name>` tags via local.tags.

resource "aws_s3_bucket" "storage_localdev" {
  count = var.storage_enabled ? 1 : 0

  # Suffix is `-ld` (not `-localdev`) to keep total bucket name ≤ 63 chars
  # even when both name_prefix, app_name, and a -test variant are involved
  # (S3's hard limit). The `quickship:env = localdev` tag is the canonical
  # marker; the suffix is just for global-name disambiguation.
  bucket        = "${local.resource_name}-storage-${data.aws_caller_identity.current.account_id}-ld"
  force_destroy = true
  tags = merge(local.tags, {
    "quickship:env" = "localdev"
  })
}

resource "aws_s3_bucket_public_access_block" "storage_localdev" {
  count = var.storage_enabled ? 1 : 0

  bucket                  = aws_s3_bucket.storage_localdev[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "storage_localdev" {
  count = var.storage_enabled ? 1 : 0

  bucket = aws_s3_bucket.storage_localdev[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------- DynamoDB tables -------------------------------------------------

resource "aws_dynamodb_table" "kv" {
  for_each = toset(var.dynamodb_tables)

  name         = "${local.resource_name}-${each.key}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "key"

  attribute {
    name = "key"
    type = "S"
  }

  # TTL auto-expires items whose `ttl` attribute (UNIX epoch seconds) is in
  # the past. Items without a `ttl` attribute live forever. Apps decide on
  # write whether to set it.
  ttl {
    enabled        = true
    attribute_name = "ttl"
  }

  tags = local.tags
}

# DynamoDB localdev twin. Same shape; PAY_PER_REQUEST means empty tables
# cost $0. docker-compose's backend env points at these via `KV_TABLE_*`.
resource "aws_dynamodb_table" "kv_localdev" {
  for_each = toset(var.dynamodb_tables)

  name         = "${local.resource_name}-${each.key}-localdev"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "key"

  attribute {
    name = "key"
    type = "S"
  }

  ttl {
    enabled        = true
    attribute_name = "ttl"
  }

  tags = merge(local.tags, {
    "quickship:env" = "localdev"
  })
}

resource "aws_iam_role_policy" "dynamodb" {
  count = length(var.dynamodb_tables) > 0 ? 1 : 0

  name = "dynamodb"
  role = module.lambda.lambda_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query",
        "dynamodb:Scan",
        "dynamodb:BatchGetItem",
        "dynamodb:BatchWriteItem",
      ]
      Resource = [for t in aws_dynamodb_table.kv : t.arn]
    }]
  })
}

# ---------- SES email -------------------------------------------------------

resource "aws_iam_role_policy" "email" {
  count = var.email_enabled ? 1 : 0

  name = "email"
  role = module.lambda.lambda_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ses:SendEmail",
        "ses:SendRawEmail",
      ]
      Resource = data.aws_ssm_parameter.platform_ses_sender_identity_arn[0].value
    }]
  })
}

# ---------- Bedrock IAM -----------------------------------------------------

resource "aws_iam_role_policy" "ai_models" {
  count = var.ai_models_enabled ? 1 : 0

  name = "ai-models"
  role = module.lambda.lambda_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
      ]
      Resource = split(",", data.aws_ssm_parameter.platform_bedrock_model_arns[0].value)
    }]
  })
}

# ---------- SSM secrets namespace (always-on) -------------------------------

resource "aws_iam_role_policy" "ssm_secrets" {
  name = "ssm-secrets"
  role = module.lambda.lambda_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath",
      ]
      Resource = [
        "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.name_prefix}/apps/${var.app_name}/*",
      ]
    }]
  })
}
