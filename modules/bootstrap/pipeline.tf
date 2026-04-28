# Platform-shared S3 bucket for CodePipeline artifacts.
#
# Per-app pipelines (created by the quickship module's pipeline.tf in Step 6)
# write build outputs here, then CodeDeploy reads them on the deploy stage.
# One bucket platform-wide; pipeline IAM scopes each app to its own
# `apps/<app_name>/` prefix.
#
# Lifecycle: 30-day expiry on artifacts. Pipelines reference the latest
# build by S3 path, older builds aren't needed once a new deploy ships.

resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket = "${var.name_prefix}-pipeline-artifacts-${data.aws_caller_identity.current.account_id}"
  tags   = local.common_tags
}

resource "aws_s3_bucket_versioning" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "pipeline_artifacts" {
  bucket                  = aws_s3_bucket.pipeline_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "pipeline_artifacts" {
  depends_on = [aws_s3_bucket_versioning.pipeline_artifacts]
  bucket     = aws_s3_bucket.pipeline_artifacts.id

  rule {
    id     = "expire-build-artifacts"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
