# Cloudflare Cache Rule that caches built static assets at the edge.
#
# Vite's `npm run build` produces hash-named filenames under
# `frontend/dist/assets/` (e.g. `index-abc123.js`). Pipeline (Step 6) packs
# them into the Lambda zip at `static/assets/`, FastAPI serves them at
# `/static/assets/...`. Because filenames change on every deploy, caching
# them forever at Cloudflare's edge is safe — old hashes simply stop being
# requested.
#
# Match is zone-wide: any subdomain serving content under /static/assets/
# benefits. Apps without that path are unaffected.

resource "cloudflare_ruleset" "static_asset_cache" {
  zone_id     = data.aws_ssm_parameter.platform_cf_zone_id.value
  name        = "${var.name_prefix}-static-asset-cache"
  description = "Cache hashed static assets (Vite output) at Cloudflare edge for 1 year. Lambda invocations drop to near-zero for asset traffic."
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules = [
    {
      description = "Cache /static/assets/* for 1 year"
      expression  = "(starts_with(http.request.uri.path, \"/static/assets/\"))"
      action      = "set_cache_settings"
      enabled     = true
      action_parameters = {
        cache = true
        edge_ttl = {
          mode    = "override_origin"
          default = 31536000 # 1 year
        }
        browser_ttl = {
          mode    = "override_origin"
          default = 31536000
        }
      }
    },
  ]
}
