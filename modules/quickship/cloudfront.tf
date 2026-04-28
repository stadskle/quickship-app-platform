# CloudFront distribution in front of the Lambda Function URL.
#
# - Uses OAC (Origin Access Control) with origin_type = "lambda" so
#   CloudFront SigV4-signs every request to the Function URL. The Function
#   URL has auth_type = AWS_IAM and a resource policy that only allows this
#   distribution to invoke — direct hits get 403.
# - Caching disabled (Managed-CachingDisabled). Tinyapps are dynamic.
# - Origin request policy Managed-AllViewerExceptHostHeader: forwards every
#   header from the viewer except Host (CloudFront regenerates Host to match
#   the Function URL's hostname, so Lambda accepts the request).
# - WAF: web_acl_arn input is the platform-shared WebACL whose single rule
#   allows requests carrying the correct X-Origin-Secret header. Cloudflare
#   injects that header via a shared Transform Rule (in the bootstrap
#   module). Direct hits to the *.cloudfront.net URL get 403 from WAF.

# AWS-managed CloudFront policy IDs are published constants and stable.
# Using the data sources (aws_cloudfront_cache_policy / origin_request_policy)
# trips a provider bug where the IDs resolve null at plan time and produce
# "inconsistent final plan" errors during apply. Hardcoding sidesteps it.
locals {
  cache_policy_caching_disabled                  = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
  origin_request_policy_all_viewer_except_host_header = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
}

resource "aws_cloudfront_origin_access_control" "lambda" {
  name                              = local.resource_name
  description                       = "OAC for quickship ${var.app_name} Lambda Function URL"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ACM certificate for the public hostname. CloudFront requires the cert to
# be in us-east-1 regardless of where the rest of the distribution lives,
# and the hostname has to be claimed as an alternate domain (aliases) for
# CloudFront to accept Cloudflare's proxied requests where the Host header
# is the public name. DNS validation is automatic via the Cloudflare
# provider creating the validation CNAME in the apex zone.
resource "aws_acm_certificate" "app" {
  provider = aws.us_east_1

  domain_name       = local.fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

locals {
  # The cert has a single domain (no SANs), so there's exactly one validation
  # record. Using `one()` keeps Terraform's plan happy — for_each can't have
  # keys derived from unknown values, but a single resource with unknown
  # attributes is fine.
  cert_validation_record = one(aws_acm_certificate.app.domain_validation_options)
}

resource "cloudflare_dns_record" "cert_validation" {
  zone_id = data.aws_ssm_parameter.cf_zone_id.value
  # ACM emits validation values with a trailing dot (FQDN form). Cloudflare
  # stores them without. Strip to match Cloudflare's stored form, otherwise
  # every plan shows a perpetual no-op diff.
  name    = trimsuffix(local.cert_validation_record.resource_record_name, ".")
  type    = local.cert_validation_record.resource_record_type
  content = trimsuffix(local.cert_validation_record.resource_record_value, ".")
  ttl     = 60
  proxied = false # validation requires direct DNS resolution
}

resource "aws_acm_certificate_validation" "app" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [cloudflare_dns_record.cert_validation.name]
}

resource "aws_cloudfront_distribution" "app" {
  enabled         = true
  is_ipv6_enabled = true
  http_version    = "http2and3"
  price_class     = "PriceClass_100"
  comment         = "quickship ${var.app_name}"
  web_acl_id      = data.aws_ssm_parameter.platform_waf_web_acl_arn.value
  aliases         = [local.fqdn]

  origin {
    origin_id                = "lambda"
    domain_name              = local.function_url_host
    origin_access_control_id = aws_cloudfront_origin_access_control.lambda.id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "lambda"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]

    cache_policy_id          = local.cache_policy_caching_disabled
    origin_request_policy_id = local.origin_request_policy_all_viewer_except_host_header
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.app.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = local.tags
}

# Allow the specific distribution to invoke the Function URL. Anyone else
# gets 403 from AWS IAM.
#
# AWS changed Function URL requirements in October 2025: new Function URLs
# need both lambda:InvokeFunctionUrl AND lambda:InvokeFunction granted to
# the CloudFront principal. Only the first is documented in older guides;
# without the second, OAC-signed requests get a Lambda 403 with body
# "Forbidden. For troubleshooting Function URL authorization issues...".
resource "aws_lambda_permission" "cloudfront_invoke" {
  statement_id           = "AllowCloudFrontInvokeFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = module.lambda.lambda_function_name
  principal              = "cloudfront.amazonaws.com"
  source_arn             = aws_cloudfront_distribution.app.arn
  function_url_auth_type = "AWS_IAM"
}

resource "aws_lambda_permission" "cloudfront_invoke_function" {
  statement_id  = "AllowCloudFrontInvokeFunction"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda.lambda_function_name
  principal     = "cloudfront.amazonaws.com"
  source_arn    = aws_cloudfront_distribution.app.arn
}
