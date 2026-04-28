# Platform-wide response-header hardening for the apex Cloudflare zone.
#
# Strips informational/server-revealing headers from every response for
# every quickship subdomain. Defense-in-depth — most of these aren't sent by
# our Lambda placeholder, but origins added later (a chatty FastAPI plugin,
# an Express-style framework via the AI codegen) may leak them.
#
# Note: Cloudflare reserves the `Server` header — Transform Rules cannot
# remove it (Cloudflare keeps `server: cloudflare` for branding). We strip
# only what's removable.

resource "cloudflare_ruleset" "response_header_strip" {
  zone_id     = data.aws_ssm_parameter.platform_cf_zone_id.value
  name        = "${var.name_prefix}-response-header-strip"
  description = "Strip server-identifying headers on every response in this zone."
  kind        = "zone"
  phase       = "http_response_headers_transform"

  rules = [
    {
      description = "Remove X-Powered-By response header"
      expression  = "true"
      action      = "rewrite"
      enabled     = true
      action_parameters = {
        headers = {
          "X-Powered-By" = { operation = "remove" }
        }
      }
    },
  ]
}
