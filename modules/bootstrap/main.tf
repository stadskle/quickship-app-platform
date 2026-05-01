data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  common_tags = merge(
    {
      "tinyapp:platform" = "v1"
      "tinyapp:managed"  = "true"
      "tinyapp:scope"    = "bootstrap"
    },
    var.tags,
  )

  # AWS Bedrock requires regional inference profile IDs for invocation in
  # most regions (the bare foundation-model ID returns ValidationException
  # "Invocation ... with on-demand throughput isn't supported"). Inference
  # profile IDs follow the pattern "<geo-prefix>.<model-id>", e.g.
  # "eu.amazon.nova-lite-v1:0" in eu-central-1. Derive the prefix from the
  # AWS region; "" if we don't know (fall back to bare model ID — caller
  # gets the underlying validation error which is at least diagnostic).
  bedrock_geo_prefix = (
    startswith(data.aws_region.current.region, "eu-") ? "eu" : (
      startswith(data.aws_region.current.region, "us-") ? "us" : (
        startswith(data.aws_region.current.region, "ap-") ? "apac" : ""
      )
    )
  )
}

# ---------------------------------------------------------------------------
# Terraform state bucket
#
# Used by consumers as the S3 backend for quickship app stacks. With Terraform
# 1.10+, locking is handled by S3 itself via use_lockfile = true in the
# backend block — no DynamoDB table required.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.name_prefix}-tfstate-${data.aws_caller_identity.current.account_id}"
  tags   = local.common_tags
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  depends_on = [aws_s3_bucket_versioning.tfstate]
  bucket     = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ---------------------------------------------------------------------------
# Account-level budget
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "account_monthly" {
  name              = "${var.name_prefix}-account-monthly"
  budget_type       = "COST"
  limit_amount      = tostring(var.budget_monthly_usd)
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2020-01-01_00:00"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_alert_emails
  }

  tags = local.common_tags
}
