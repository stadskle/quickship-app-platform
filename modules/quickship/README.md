# quickship / app

Provisions one quickship end-to-end: Lambda + Function URL + execution role + log group + CloudFront distribution + per-app Cloudflare Access app + DNS record. Wraps `terraform-aws-modules/lambda/aws ~> 8.0` plus the `cloudflare/cloudflare ~> 5.0` provider.

The auth model is **chain of trust** — every layer enforces something, app code is auth-naive:

```
[Browser]
   ↓
[Cloudflare]
   ├─ Zero Trust Access auth (Email PIN by default)
   ├─ adds  Cf-Access-Authenticated-User-Email
   └─ adds  X-Origin-Secret  (via shared Transform Rule in `bootstrap`)
   ↓
[CloudFront]
   ├─ AWS WAFv2 verifies X-Origin-Secret → allow
   ├─ Managed-AllViewerExceptHostHeader → regenerates Host for origin
   └─ OAC SigV4-signs the request to Lambda Function URL
   ↓
[Lambda Function URL]   auth_type = AWS_IAM
   └─ resource policy allows only this distribution to invoke
   ↓
[Handler]   reads Cf-Access-Authenticated-User-Email and trusts it
```

Direct hits to any layer's URL fail closed:
- Function URL → 403 (IAM, no SigV4)
- CloudFront `*.cloudfront.net` → 403 (WAF, no `X-Origin-Secret`)
- User-facing hostname unauthenticated → Cloudflare Access challenge

---

## What it provisions

**AWS** (via `terraform-aws-modules/lambda/aws`):

| Resource | Purpose |
|---|---|
| `aws_lambda_function` | `python3.12`, **arm64** (Graviton), 256 MB / 10s defaults. |
| `aws_lambda_function_url` | `auth_type = AWS_IAM`. Only the per-app CloudFront distribution can invoke. |
| `aws_iam_role` | Execution role tagged `tinyapp:name=<app>`. |
| `aws_cloudwatch_log_group` | 30-day retention default. |

**AWS** (added directly):

| Resource | Purpose |
|---|---|
| `aws_cloudfront_origin_access_control` | `origin_type = lambda`, SigV4-signs every origin request. |
| `aws_cloudfront_distribution` | `Managed-CachingDisabled` + `Managed-AllViewerExceptHostHeader`. Attached to the platform-shared WAF WebACL. `PriceClass_100`. |
| `aws_lambda_permission` | Grants only this distribution `lambda:InvokeFunctionUrl`. |

**Cloudflare**:

| Resource | Purpose |
|---|---|
| `cloudflare_dns_record` | Proxied CNAME `<subdomain>.<apex>` → CloudFront default domain. |
| `cloudflare_zero_trust_access_application` | Self-hosted Access app, 24h session. |
| `cloudflare_zero_trust_access_policy` | `allow` rule, auto-classifies `email` vs `email_domain` from `allowed_principals`. |

**Placeholder code** (in `placeholder/handler.py`):

50-line auth-naive handler — reads `Cf-Access-Authenticated-User-Email` and returns a JSON greeting. No JWT verification, no native deps, no Docker required for the build. Replaced by template-quickship app code on first pipeline deploy.

---

## Usage (per-app repo / consumer)

```hcl
module "hello" {
  source = "git::https://<host>/<owner>/ai-apps-platform.git//modules/quickship?ref=<tag>"

  app_name           = "hello"
  allowed_principals = ["alice@example.com", "*@yourcompany.com"]
  web_acl_arn        = data.aws_ssm_parameter.quickship_waf_arn.value
}
```

Where `web_acl_arn` comes from the bootstrap module's `origin_waf_web_acl_arn` output (one shared WebACL per platform). The `cloudflare` provider must be configured at the consumer's root.

---

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `app_name` | string | – | Lowercase alphanum/hyphen, 3-32 chars. Drives `tinyapp:name` tag, resource names, default subdomain. |
| `allowed_principals` | list(string) | – | Mix of explicit emails and `*@domain` wildcards. Auto-classified into Cloudflare include rules. |
| `web_acl_arn` | string | – | Platform-shared WAFv2 WebACL ARN. Pass `module.quickship_bootstrap.origin_waf_web_acl_arn`. |
| `database_enabled` | bool | – (required) | `true` → provision a Postgres role + database for this app inside the platform Neon project, inject `DATABASE_URL` into Lambda env. `false` → no DB resources. Pick deliberately per app. |
| `neon_project_id` / `neon_default_branch_id` / `neon_pooler_host` | string | `null` | Pass the matching `module.quickship_bootstrap.neon_*` outputs when `database_enabled = true`. |
| `subdomain` | string | `null` (= `app_name`) | Override default subdomain. |
| `name_prefix` | string | `"quickship"` | Should match the bootstrap module's `name_prefix`. |
| `memory_mb` | number | `256` | Lambda memory. |
| `timeout_seconds` | number | `10` | Lambda timeout. |
| `runtime` | string | `"python3.12"` | Lambda runtime. |
| `log_retention_days` | number | `30` | CloudWatch log retention. |
| `environment` | map(string) | `{}` | Lambda env vars. |
| `secret_names` | list(string) | `[]` | Per-app secret names. Each becomes an SSM SecureString placeholder under `/<name_prefix>/apps/<app_name>/<name>` and is injected into Lambda env as `<NAME_UPPERCASE>`. Validated `^[a-z][a-z0-9_]*$`. See "Secrets" below. |
| `pipeline_enabled` | bool | `true` | Provision a per-app CodePipeline + CodeBuild that builds the GitHub repo and `aws lambda update-function-code`s the Lambda. Set `false` for manual deploys (rare). |
| `git_repo` | string | `null` | GitHub repo in `owner/repo` form (e.g., `alice/hello-world`). NOT a URL. Required when `pipeline_enabled = true`. The repo must already exist; the platform's CodeConnection must be authorized for that owner. |
| `git_branch` | string | `"main"` | Branch that triggers builds. |
| `developers` | list(string) | `[]` | Names of developers (matching `developer` module calls) who get debug/operate access to this app. See "Developer access" below. |
| `tags` | map(string) | `{}` | Merged on top of platform tags. |

---

## Outputs

| Name | Description |
|---|---|
| `url` / `fqdn` | Public URL through Cloudflare Access. |
| `function_name` / `function_arn` | The Lambda. |
| `function_url` | Raw Function URL — direct hits get 403 from IAM. |
| `cloudfront_distribution_id` / `cloudfront_domain_name` | The per-app CloudFront distribution. Direct hits to the cloudfront.net domain get 403 from WAF. |
| `role_arn` / `role_name` | Execution role identifiers. |
| `log_group_name` | CloudWatch log group. |
| `pipeline_name` / `pipeline_console_url` | Per-app CodePipeline name and direct console URL (null when `pipeline_enabled = false`). |
| `tags` | Effective tag map. |

---

## Tag convention

```
tinyapp:name      = <app_name>
tinyapp:platform  = v1
tinyapp:managed   = true
tinyapp:scope     = app
```

Plus consumer-level provider `default_tags` and the module's `tags` input.

---

## Localdev twins for S3 and DynamoDB

For every per-app S3 bucket (`storage_enabled = true`) and DynamoDB table (`dynamodb_tables = [...]`), the module also provisions a `-localdev` twin tagged `quickship:env = localdev`. Empty DynamoDB tables and S3 buckets cost $0, so the duplicate is free.

The twins exist to give `docker compose up` a real AWS endpoint to talk to (via the developer's AWS profile) instead of the host-disk fallback in `kv.py` / `storage.py`. Real DynamoDB semantics (TTL, conditional writes, batch ops), real S3 (presigned URLs, multipart uploads) — without a localstack container or risk of polluting prod data.

The Lambda execution role's IAM only references the **prod** ARNs — production code can't reach localdev. The developer's tag-based access policy covers both because both carry the dev-tag entries from `local.tags`.

The app template's `docker-compose.yml` (configured by `bootstrap.sh`) sets `KV_TABLE_<NAME>` and `STORAGE_BUCKET` env vars pointing at the `-localdev` twins, so the helpers automatically use them.

## Database (when `database_enabled = true`)

- A Postgres role and database — both named `<app_name>` — are created inside the platform-shared Neon project. The role **owns** its database — full DDL/DML inside it.
- Isolation: the role has no cross-database `CONNECT` grant. Apps cannot see or touch each other's data.
- Schema is **entirely the app's concern**. The platform doesn't pre-create any tables, doesn't impose JSONB or any other shape, and doesn't run migrations. Whatever the app decides to do in its database is its business.
- Connection string is mirrored to two places:
  - `DATABASE_URL` Lambda env var — what the app reads at runtime.
  - SSM SecureString at `/<name_prefix>/apps/<app_name>/database_url` — for operator psql access:
    ```bash
    psql "$(aws ssm get-parameter --name /quickship/apps/<app>/database_url --with-decryption --query Parameter.Value --output text)"
    ```
- Rotation: `terraform apply -replace=module.<app>.neon_role.app[0]` regenerates the password and pushes it to SSM + Lambda env in one apply.

---

## Secrets (when `secret_names` is non-empty)

Per-app secrets are managed in three places:

- **Terraform** declares the names. Each `secret_names` entry produces an `aws_ssm_parameter` (SecureString) at `/<name_prefix>/apps/<app_name>/<name>` with placeholder value `"REPLACE_ME"` and `lifecycle.ignore_changes = [value]`.
- **Operator** sets the real value out-of-band (CLI/console).
- **Terraform** reads the value at the next plan and injects it into the Lambda env as `<NAME_UPPERCASE>`.

Two-apply workflow on first creation:

```bash
# 1. Add to secret_names, apply. Placeholder created, Lambda env = "REPLACE_ME".
terraform apply

# 2. Set the real value.
aws ssm put-parameter \
  --name /quickship/apps/<app>/<name> \
  --value 'real-value' \
  --type SecureString \
  --overwrite \
  --region <region>

# 3. Re-apply. TF reads new value, updates Lambda env.
terraform apply
```

Rotation skips step 1 — just `put-parameter --overwrite` and re-apply.

The Lambda role's `ssm_secrets` policy already grants read on the wildcard path `/<name_prefix>/apps/<app_name>/*`, so adding a secret never requires an IAM change. The wildcard is intentional: tightening to per-name ARNs adds friction with no real security gain since the namespace is the app's own.

### Auto-added secret: `anthropic_api_key`

When `ai_models_enabled = true`, the module appends `anthropic_api_key` to the effective secret list automatically. Apps that turn on AI thus get an SSM placeholder for the Anthropic API key without a separate `secret_names` round-trip — they can use `app.lib.ai_claude` directly after populating the value once. If the operator already lists `anthropic_api_key` in `secret_names`, dedup keeps `for_each` happy.

**Trade-off**: secrets land in the Lambda env config in cleartext (`lambda:GetFunctionConfiguration` can read them) and in TF state. Same risk profile as `DATABASE_URL`. If you need bank-grade secret handling, this module isn't the right vehicle.

---

## Pipeline (when `pipeline_enabled = true`, the default)

Per-app CI/CD: `GitHub push → CodePipeline source → CodeBuild → aws lambda update-function-code`. No CodeDeploy. Build runs on `aws/codebuild/amazonlinux2-aarch64-standard:3.0` (arm64, matches Lambda Graviton so wheels load).

**0-drift contract**: when the pipeline is on, the lambda module call sets `ignore_source_code_hash = true`. Terraform owns the function shell; the pipeline owns the code. After the first pipeline run, `terraform plan` is clean.

### `git_repo` input — common amateur traps

`git_repo` is the most-paste-wrong input on this module. The accepted form is `owner/repo` — exactly what you'd see in the GitHub URL between `github.com/` and the next `/`. If the user pastes any of these, fix it:

| What the user pastes | What it should be |
|---|---|
| `https://github.com/alice/hello-world.git` | `alice/hello-world` |
| `https://github.com/alice/hello-world` | `alice/hello-world` |
| `git@github.com:alice/hello-world.git` | `alice/hello-world` |
| `hello-world` | `alice/hello-world` (need the owner) |

Other failure modes:

- **Repo doesn't exist on GitHub yet.** Bootstrapping a fresh app with `bootstrap.sh` only does `git init` locally. The user must `gh repo create alice/hello-world --source . --push --private` (or create via the GitHub web UI and `git push`) before the pipeline can find it. `terraform apply` will succeed (the pipeline is just a plan-time string), but the first source action will fail with `Repository not found` until the GitHub repo exists and has commits.
- **CodeConnection not authorized for the owner.** When the platform admin set up the CodeConnection in bootstrap, the OAuth handshake authorised it for a specific GitHub account or organisation. If `git_repo` references an owner the connection isn't authorised for, the source action fails the same way. Fix: AWS Console → Developer Tools → Settings → Connections → click the connection → "Configure" the GitHub App to grant access to the desired account/org.
- **Branch mismatch.** `git_branch` defaults to `main`. If the repo's default is `master`, set `git_branch = "master"` or rename the branch (`git branch -m master main && git push -u origin main`).

### Pipeline failure modes (operator FAQ)

- `Source action: Repository not found` → repo doesn't exist on GitHub or the CodeConnection isn't authorised for that owner. See above.
- `Build action: ModuleNotFoundError` at Lambda runtime → buildspec didn't pip-install for arm64 / Python 3.12. Use `pip install -t ...` on the arm64 runner, not `--platform x86_64`.
- `Build action: Lambda update fails (CodeStorageExceededException)` → too many old versions. The lambda module purges old versions; if you flipped `publish = true`, you'll accumulate. Solution: keep `publish = false` (default).

---

## Developer access (when `developers` is non-empty)

For each name in `developers`, this module emits one **resource tag** — `quickship:dev:<name> = "1"` — onto every per-app resource (Lambda, S3, DynamoDB, log groups, CodeBuild, CodePipeline, IAM, SSM secrets). The companion `developer` module attaches a single managed policy to each developer's IAM user, with conditions that match the resource tag against the user's `quickship-username` principal tag:

```
aws:ResourceTag/quickship:dev:${aws:PrincipalTag/quickship-username} = "1"
```

Net effect: when developer Alice is in your `developers` list, all of this app's resources get tagged `quickship:dev:alice = "1"`, and her single managed policy lets her debug any resource where that tag matches. **Per-app managed policies are no longer attached to user** — the entire access model is tag-driven.

### What the developer can do (when listed)

| Capability | Tag-scoped grant |
|---|---|
| Lambda | `GetFunction*`, `InvokeFunction` (NOT `UpdateFunctionCode` — pipeline owns deploys) |
| CloudWatch Logs | full read/tail on the app's log groups |
| CloudWatch Logs Insights | query (account-wide; tag conditions don't apply to `StartQuery`'s log-group selection — accept the read-grant) |
| CodeBuild | start/retry/inspect builds for this app |
| CodePipeline | get state, start execution for this app |
| S3 | RW on the app's bucket (when `storage_enabled = true`) |
| DynamoDB | RW on the app's tables |
| SSM secrets | Get + Put on the app's secrets path |

Bedrock `InvokeModel` is granted unconditionally to all developers (model ARNs are AWS-managed, untaggable). Minor over-grant — devs not on AI-enabled apps can still invoke. Mitigation: budget alerts in bootstrap.

Deliberately NOT granted: `ses:SendEmail` (local helper falls back to stderr; keep accidental real emails out of dev).

### Adding / removing developers

- **Add to a new app**: append name to `developers`, run `/configure`. The module re-tags resources with their dev marker. No new managed policy attached anywhere.
- **Remove**: drop the name, `/configure`. Tags removed; their access fails the policy condition immediately.
- **Instant revocation across all apps**: rotate (or delete) the developer's access key — see the `developer` module README.

### Scaling

The IAM 10-managed-policies-per-user cap is **no longer a constraint** — each developer has one managed policy regardless of app count. The new ceiling is **AWS resource-tag limits: 50 tags per resource** (so up to 50 developers per app, comfortable for any solo or small-team scenario).

---

## Verification after apply

1. Hit `https://<app>.<apex>/` → Cloudflare Access challenges → after Email PIN auth, JSON `{"ok":true,"from":"quickship-placeholder","user":"<your-email>",...}`.
2. Hit the raw `*.cloudfront.net` domain (`terraform output cloudfront_domain_name`) → `403 Forbidden` from WAF (no `X-Origin-Secret`).
3. Hit the raw Function URL (`terraform output function_url`) → `403 Forbidden` from AWS IAM (no SigV4 signature).

---

## Notes

- **No Docker required.** Placeholder has no native deps; the lambda module zips Python source directly.
- **CloudFront deploy time.** First apply takes ~5-10 minutes for the distribution to deploy. Subsequent applies are fast unless the distribution itself changes.
- **Code lifecycle.** This module owns the placeholder source. When Step 6's CodePipeline lands, set `ignore_source_code_hash = true` on the lambda module call so Terraform stops fighting pipeline-deployed code.
- **Region.** Inherits from consumer's `aws` provider. Platform default is `eu-central-1`. CloudFront is global; the WAF WebACL is in us-east-1 (managed by the bootstrap module's `aws.us_east_1` provider alias).
