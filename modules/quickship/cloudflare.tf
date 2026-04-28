# Cloudflare-side resources for one quickship.
#
# Flow per request:
#   1. User hits https://<subdomain>.<apex>/
#   2. Cloudflare proxies (orange-cloud) — Zero Trust Access intercepts.
#   3. If unauthenticated, redirects to <team>.cloudflareaccess.com (Email PIN by default).
#   4. After auth, Cloudflare adds Cf-Access-Authenticated-User-Email header.
#   5. Platform-shared Transform Rule (in bootstrap) adds X-Origin-Secret.
#   6. Cloudflare proxies to origin = the per-app CloudFront distribution.
#   7. WAF on CloudFront verifies X-Origin-Secret → allow.
#   8. CloudFront SigV4-signs to Function URL (OAC) and forwards.
#   9. Lambda runs the placeholder; reads Cf-Access-Authenticated-User-Email
#      directly without verifying signatures (the chain is the auth).

resource "cloudflare_dns_record" "app" {
  zone_id = data.aws_ssm_parameter.cf_zone_id.value
  name    = local.fqdn
  type    = "CNAME"
  content = aws_cloudfront_distribution.app.domain_name
  ttl     = 1 # required when proxied = true
  proxied = true
}

resource "cloudflare_zero_trust_access_policy" "app" {
  account_id = data.aws_ssm_parameter.cf_account_id.value
  name       = "${local.resource_name}-allow"
  decision   = "allow"

  include = concat(
    [for e in local.email_principals : { email = { email = e } }],
    [for d in local.domain_principals : { email_domain = { domain = d } }],
  )
}

resource "cloudflare_zero_trust_access_application" "app" {
  account_id       = data.aws_ssm_parameter.cf_account_id.value
  name             = var.app_name
  domain           = local.fqdn
  type             = "self_hosted"
  session_duration = "24h"

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.app.id
      precedence = 1
    },
  ]
}
