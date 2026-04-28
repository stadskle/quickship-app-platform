terraform {
  # 1.10+ for S3 native state locking (use_lockfile = true).
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.0"
      configuration_aliases = [aws.us_east_1]
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    neon = {
      source  = "kislerdm/neon"
      version = "~> 0.13"
    }
  }
}
