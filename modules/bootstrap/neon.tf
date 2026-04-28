# Platform-shared Neon project. One project hosts all quickship apps in this
# platform; each quickship module instance creates its own role + database
# inside this project. Apps share compute hours and storage (free tier:
# 191.9 hr/mo, 0.5 GB) — fine for low-traffic internal tools, easy to split
# off a hot app onto its own project later if needed.

resource "neon_project" "platform" {
  name       = "${var.name_prefix}-platform"
  region_id  = var.neon_region
  pg_version = var.neon_pg_version

  # Neon Free tier caps point-in-time-restore history at 6 hours; paid tiers
  # allow more. Bump this if you upgrade the project.
  history_retention_seconds = 21600
}
