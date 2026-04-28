# Platform-shared SES sender identity for the apex Cloudflare zone.
#
# DNS validation is automatic via three Cloudflare DKIM CNAME records.
# Apps with email_enabled = true (in the quickship module) receive IAM
# permission to send via this identity; their from-address is any
# `<anything>@<apex>` (e.g. noreply@<apex>, or <app_name>@<apex>).
#
# SES starts in sandbox mode — outbound is restricted to verified
# recipients. Request production access in the AWS Console (SES → Account
# dashboard) when you need to send to arbitrary addresses.

data "cloudflare_zone" "apex" {
  count = var.email_enabled ? 1 : 0

  zone_id = data.aws_ssm_parameter.platform_cf_zone_id.value
}

resource "aws_sesv2_email_identity" "platform" {
  count = var.email_enabled ? 1 : 0

  email_identity = data.cloudflare_zone.apex[0].name

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }

  tags = local.common_tags
}

resource "cloudflare_dns_record" "ses_dkim" {
  count = var.email_enabled ? 3 : 0

  zone_id = data.aws_ssm_parameter.platform_cf_zone_id.value
  name    = "${aws_sesv2_email_identity.platform[0].dkim_signing_attributes[0].tokens[count.index]}._domainkey.${data.cloudflare_zone.apex[0].name}"
  type    = "CNAME"
  content = "${aws_sesv2_email_identity.platform[0].dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"
  ttl     = 300
  proxied = false # email DNS validation requires direct resolution
}

# SPF — declare amazonses.com as the only authorized sender for the apex.
# Hard fail (-all) because no other systems send mail as this domain.
resource "cloudflare_dns_record" "spf" {
  count = var.email_enabled ? 1 : 0

  zone_id = data.aws_ssm_parameter.platform_cf_zone_id.value
  name    = data.cloudflare_zone.apex[0].name
  type    = "TXT"
  content = "v=spf1 include:amazonses.com -all"
  ttl     = 300
  proxied = false
}

# DMARC — reject anything that fails alignment. Safe from day one because
# DKIM aligns on ai-apps.cloud (we sign with that domain) and that's
# enough for DMARC to pass on legitimate mail. SPF doesn't need to align
# because at least one of DKIM/SPF passing is sufficient.
#
# No `rua=` reporting address — keeps the setup simple. To collect
# aggregate reports later, add `rua=mailto:dmarc@<domain>` and stand up a
# mailbox or use a free DMARC service.
resource "cloudflare_dns_record" "dmarc" {
  count = var.email_enabled ? 1 : 0

  zone_id = data.aws_ssm_parameter.platform_cf_zone_id.value
  name    = "_dmarc.${data.cloudflare_zone.apex[0].name}"
  type    = "TXT"
  content = "v=DMARC1; p=reject; sp=reject"
  ttl     = 300
  proxied = false
}
