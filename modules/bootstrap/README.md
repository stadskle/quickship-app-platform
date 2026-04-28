# quickship / bootstrap

Turns an AWS account into a quickship **platform**. Apply once per account; every per-app stack consumes the outputs of this module.

The module is intentionally generic — same code can bootstrap any organisation's account by changing inputs.

---

## What it provisions

| Resource | Purpose |
|---|---|
| `aws_s3_bucket.tfstate` | Dedicated S3 bucket for quickship **app** tfstate (S3 native locking — no DynamoDB). Versioned, AES256 encrypted, public access blocked, noncurrent versions expire after 90 days. |
| `aws_budgets_budget.account_monthly` | Account-level monthly USD budget. Notifies on 80% actual + 100% forecasted. |
| `aws_ssm_parameter` × 4 | Placeholder SSM parameters for Cloudflare and Neon credentials. Created with `REPLACE_ME` and `lifecycle { ignore_changes = [value] }` so operator-set values are not overwritten. |
| `aws_codeconnections_connection` (per provider) | Created in `PENDING` state for every provider listed in `git_connection_providers`. Used by per-app CodePipelines later. (Service was previously branded *CodeStar Connections*; the project-level CodeStar service was deprecated in 2024 but the connections service was rebranded and remains supported.) |
| `neon_project` | One Neon project shared across all quickship apps in the platform. Pg16, Frankfurt by default. Each per-app `quickship` instance creates its own role + database inside this project; compute and storage are shared. Free tier (191.9 hr/mo, 0.5 GB) covers a small platform; bump `neon_pg_version` / `neon_region` inputs if you need different. |
| `aws_sesv2_email_identity` (when `email_enabled = true`) | Verified SES sender identity for the apex Cloudflare zone, with DKIM signing. Three CNAME records auto-created in Cloudflare. Apps with email_enabled receive IAM permission to send from `<anything>@<apex>`. Starts in **SES sandbox mode** — request production access via AWS Console (SES → Account dashboard) before sending to unverified recipients. |
| Bedrock model list | A list of foundation-model ARNs derived from `bedrock_models` input. Per-app modules grant `InvokeModel` on these when `ai_models_enabled = true`. Default `amazon.nova-lite-v1:0` (one of the few Bedrock models in eu-central-1; no Anthropic models there yet). Add to the list in the bootstrap input when more models become available in the platform region. |

---

## Usage

```hcl
module "quickship_bootstrap" {
  source = "git::https://<host>/<owner>/ai-apps-platform.git//modules/bootstrap?ref=<tag>"

  name_prefix              = "quickship"
  budget_monthly_usd       = 50
  budget_alert_emails      = ["you@example.com"]
  git_connection_providers = ["GitLab"]   # optional; [] disables CodeStar

  tags = {
    Environment = "prod"
    Owner       = "platform-team"
  }
}
```

The module declares `aws ~> 6.0` and `terraform >= 1.10`. Provider config (region, default tags, credentials) lives in the consumer.

---

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | – | Lowercase identifier used in resource names and SSM paths. 3-32 chars, must start with a letter. |
| `budget_monthly_usd` | number | `200` | Monthly USD threshold for the account budget. |
| `budget_alert_emails` | list(string) | – | Recipients of budget notifications. At least one required. |
| `tags` | map(string) | `{}` | Extra tags merged onto every bootstrap-created resource. |
| `git_connection_providers` | set(string) | `[]` | Subset of `{GitHub, GitHubEnterpriseServer, GitLab, GitLabSelfManaged, Bitbucket}`. |

---

## Outputs

| Name | Description |
|---|---|
| `tfstate_bucket_name` / `tfstate_bucket_arn` | Tinyapp app tfstate bucket. Reference in per-app backend blocks. |
| `account_id` | AWS account the bootstrap was applied in. |
| `platform_tags` | Merged platform tag map. Useful for downstream `default_tags`. |
| `ssm_secret_paths` | Map of SSM parameter **names** for platform credentials. |
| `ssm_secret_arns` | Map of SSM parameter **ARNs**. Use to scope IAM read policies in the quickship module. |
| `git_connection_arns` | CodeConnections ARNs keyed by provider. |

Backend snippet for per-app stacks (consumer side):

```hcl
terraform {
  backend "s3" {
    bucket       = "quickship-tfstate-<account-id>"
    key          = "apps/<app-name>.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true   # S3 native locking
  }
}
```

---

## First-time apply (chicken-and-egg)

The bootstrap module creates SSM placeholders that the consumer's `cloudflare` provider needs to read at plan time to configure. On a brand-new account those placeholders don't exist yet, so a single `terraform apply` fails with `reading SSM Parameter (/.../cloudflare/api_token): couldn't find resource`.

Resolve in three steps. **Only required the first time** the bootstrap is applied in a given account.

```bash
# 1. Create the SSM placeholders only — no Cloudflare provider needed for this.
#    (Single line so multi-line paste doesn't get mangled by trailing whitespace.)
terraform apply -target=module.quickship_bootstrap.aws_ssm_parameter.cloudflare_api_token -target=module.quickship_bootstrap.aws_ssm_parameter.cloudflare_account_id -target=module.quickship_bootstrap.aws_ssm_parameter.cloudflare_zone_id -target=module.quickship_bootstrap.aws_ssm_parameter.neon_api_key

# 2. Populate them with real values (replace TOKEN / ACCOUNT_ID / ZONE_ID / NEON_KEY,
#    and adjust --region to whatever region the platform lives in).
aws ssm put-parameter --name /quickship/cloudflare/api_token  --value 'TOKEN'      --type SecureString --overwrite --region eu-central-1
aws ssm put-parameter --name /quickship/cloudflare/account_id --value 'ACCOUNT_ID' --type String       --overwrite --region eu-central-1
aws ssm put-parameter --name /quickship/cloudflare/zone_id    --value 'ZONE_ID'    --type String       --overwrite --region eu-central-1
aws ssm put-parameter --name /quickship/neon/api_key          --value 'NEON_KEY'   --type SecureString --overwrite --region eu-central-1

# 3. Full apply — Cloudflare provider can now configure; everything else proceeds.
terraform apply
```

After this, every subsequent `terraform apply` in this account is a single command — the placeholders exist and the data sources resolve at plan time normally. The chicken-and-egg only bites on the very first apply per account.

---

## Post-apply manual steps

These are the one-time, by-hand actions that can't (or shouldn't) be automated. Step 4 (Populate the SSM placeholders) gates the second `terraform apply` of the first-time procedure above; the others can be done whenever the relevant downstream step calls for the values.

### 1. Enrol Cloudflare Zero Trust (one-off, free)

`one.dash.cloudflare.com` → pick a team name (becomes `<team>.cloudflareaccess.com`) → choose **Free** plan (50 users). A payment method is required even on Free; you're only charged if the seat cap is exceeded.

### 2. Create the Cloudflare API token

`dash.cloudflare.com` → My Profile → API Tokens → **Create Custom Token**.

The least-privilege permission set the quickship module needs is below. Skip every row not listed in either table — they're unrelated to what quickship does with Cloudflare.

**Account permissions** — open the *Cloudflare One / Zero Trust* group:

| Row | Read | Edit | Why |
|---|:---:|:---:|---|
| `Access: Organizations` | ✓ | – | The quickship module reads `auth_domain` (your `<team>.cloudflareaccess.com`) via the `cloudflare_zero_trust_organization` data source. |
| `Access: Apps` | – | ✓ | Create/update each app's `cloudflare_zero_trust_access_application`. |
| `Access: Policies` | – | ✓ | Create/update each app's `cloudflare_zero_trust_access_policy`. |
| `Access: Identity Providers` | – | ✓ | Not used by the module today; included so a later IdP feature doesn't require a token re-edit. Drop this row if you want minimum minimum. |

In Cloudflare's permission model `Edit` implicitly grants the Read needed for normal CRUD and refresh — you don't need to additionally tick Read on the Edit rows above.

**Zone permissions** — open the *DNS & Zones* group:

| Row | Read | Edit | Why |
|---|:---:|:---:|---|
| `Zone` | ✓ | – | The quickship module reads the apex zone `name` via the `cloudflare_zone` data source. |
| `DNS` | – | ✓ | Create the CNAME pointing `<app>.<apex>` at each app's CloudFront distribution. |

**Zone permissions** — open the *Rules & Configuration* group:

| Row | Read | Edit | Why |
|---|:---:|:---:|---|
| `Zone Transform Rules` | – | ✓ | The bootstrap module manages a single shared Transform Rule that injects the `X-Origin-Secret` header on all subdomains, verified by the platform's WAF on CloudFront. |
| `Managed headers` | – | ✓ | Required *in addition to* `Zone Transform Rules` for the `http_request_late_transform` phase Cloudflare uses for header rewrites. Cloudflare's permission split is undocumented but enforced — without this row, `terraform apply` 403s when creating the ruleset. |

**Resource scopes** (below the permissions):
- **Account resources**: Include → *specific account* → your account.
- **Zone resources**: Include → *specific zone* → your apex domain (or *all zones from an account* if you'll publish apps under multiple apex zones).

**TTL**: no expiry, or pick a long one — rotate manually.

Token value is shown once — copy it. Permissions can be edited later without invalidating the token (the value stays the same when you change scopes).

### 3. Create a Neon API key

`console.neon.tech` → Account settings → API keys → New API key. Copy.

### 4. Populate the SSM placeholders

```bash
aws ssm put-parameter --name /<prefix>/cloudflare/api_token  --value 'TOKEN'      --type SecureString --overwrite
aws ssm put-parameter --name /<prefix>/cloudflare/account_id --value 'ACCOUNT_ID' --type String       --overwrite
aws ssm put-parameter --name /<prefix>/cloudflare/zone_id    --value 'ZONE_ID'    --type String       --overwrite
aws ssm put-parameter --name /<prefix>/neon/api_key          --value 'KEY'        --type SecureString --overwrite
```

The `lifecycle { ignore_changes = [value] }` on each parameter prevents Terraform from overwriting these on subsequent applies.

The Cloudflare zone whose ID you store at `cloudflare/zone_id` is the apex under which apps are published — a quickship called `hello-world` becomes `hello-world.<zone-name>`. The quickship module derives the apex domain name and the Zero Trust team domain from the zone_id and account_id via the Cloudflare API; you don't set them as separate placeholders.

### 5. Authorize each git connection

For every provider in `git_connection_providers`:

Console → Developer Tools → Settings → **Connections** → click the `<prefix>-<provider>` connection → **Update pending connection** → complete OAuth → status flips `PENDING` → `AVAILABLE`.

Connection ARN is stable; re-authorising never changes it.

---

## Notes

- **Region.** The module has no region variable — it inherits from the consumer's `aws` provider block. Bootstrap resources are account-scoped; pick whatever region your provider points at (eu-central-1 is the platform default).
- **Tags.** All bootstrap resources carry `tinyapp:platform=v1`, `tinyapp:managed=true`, `tinyapp:scope=bootstrap`. Consumer-level `default_tags` and the module's `tags` input are merged on top.
- **Re-apply safety.** All resources are idempotent. SSM placeholders ignore manual value changes. Budget/connection re-runs are no-ops once authorised.
