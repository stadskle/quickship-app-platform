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
    {
      # Force-uncache the SPA app shell. Cloudflare's default for HTML is
      # not to cache, but a tweaked zone setting or a stray origin
      # Cache-Control header could change that — and a cached index.html
      # serving stale hash references after a deploy is a hard-to-diagnose
      # "the site looks broken on my browser" footgun. Explicit rule
      # guarantees index.html is always fresh regardless of zone defaults.
      #
      # `/` covers SPA root (FastAPI serves index.html there). `*.html`
      # covers any direct .html requests (rare for SPAs but harmless).
      description = "Never cache the SPA app shell"
      expression  = "(http.request.uri.path eq \"/\") or (ends_with(http.request.uri.path, \".html\"))"
      action      = "set_cache_settings"
      enabled     = true
      action_parameters = {
        cache = false
      }
    },
  ]
}
