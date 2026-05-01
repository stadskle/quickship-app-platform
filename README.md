# quickship platform

Infrastructure-as-code (Terraform modules) for the **quickship** internal-developer-platform: a tiny, opinionated stack that lets non-developers ship small SaaS-style internal tools by talking to Claude.

This repo is the **platform side** — the modules a platform admin applies once to set up the shared AWS + Cloudflare + Neon plumbing, plus a per-app module that each new app's `infra/` calls. The companion **app template** lives at [stadskle/quickship-app-template](https://github.com/stadskle/quickship-app-template).

> **Audience**: you're setting up a quickship platform for yourself or a small team. You're comfortable with Terraform, AWS, and reading module READMEs. The end users of *apps* you'll later build don't need any of that.

---

## Design principles

1. **Audience first: non-developers using Claude.** Single commands beat config files. Opinionated beats generic. The friction we accept is the friction the human can't help feeling — we don't make trade-offs for "future flexibility" they'll never use.

2. **Bounded scope.** Five capabilities: Postgres, S3, DynamoDB, SES, Bedrock. Anything else (Redis, SQS, Step Functions, RDS, …) needs a platform-admin discussion. Keeps Claude from inventing AWS services and amateurs from pulling in operational complexity they can't reason about.

3. **Auth at the edge, naive in code.** Chain of trust: Cloudflare Access → CloudFront WAF → OAC SigV4 → Lambda IAM. App code reads `Cf-Access-Authenticated-User-Email` and trusts it. No JWT validation, no auth library, no signup flow.

4. **Email is the user identity.** No user table, no UUIDs. The Cloudflare-vended email goes directly into `owner_email TEXT` columns. Stable across sessions; query scoping uses it; audit trail uses it.

5. **Same code in dev and prod.** Every helper has a transparent local fallback (postgres → docker-compose, S3 → `./uploads`, DynamoDB → SQLite, SES → stderr). No `if PROD:` branches in app code. "Works on a fresh clone + `docker compose up`" is the bar before "works deployed."

6. **One profile per developer, no console access required.** `aws configure --profile quickship` and you're done. No SSO permission sets, no role-assuming, no MFA QR scanning. We trade strict security depth for onboardable usability and compensate with per-app permission scoping + access-key rotation.

7. **Capabilities default off; Claude enables them.** Bootstrap asks two questions (app name, allowed users). The newbie typing it doesn't know whether they need DynamoDB. Claude turns capabilities on as it learns what the app does — by editing `terraform.tfvars` and running `/deploy`.

8. **SSM is the cross-repo glue.** Bootstrap publishes platform facts (WAF ARN, Neon project, pipeline bucket, this repo's URL, …) to SSM. Per-app Terraform data-reads them. Apps don't thread outputs through module calls; new repos have nothing to configure.

9. **No secrets in Terraform state where avoidable.** IAM access keys are minted by `aws iam create-access-key` post-apply, not by `aws_iam_access_key`. SSM secret values are populated out-of-band; TF `lifecycle.ignore_changes = [value]` keeps them stable across applies.

10. **Zero drift after the first deploy.** Terraform owns the Lambda's function shell; the CodeBuild pipeline owns its code (`ignore_source_code_hash = true`). After bootstrap, `git push` is the only deploy verb — `terraform apply` only when infra actually changes.

---

## Security model & limitations

Quickship optimises for **safe-enough internal tools built by amateurs**, not enterprise-grade compliance. The defaults are reasonable; the gaps are real. Read this section before deciding whether to put anything sensitive on it.

### What you get

- **Edge auth that can't be bypassed.** Cloudflare Access (Email PIN) → CloudFront WAF (origin-secret check) → OAC SigV4-signed Lambda URL. Direct hits to any layer's URL return 403; the chain is end-to-end tamper-evident.
- **Per-app IAM scoping.** Each app's Lambda execution role is policy-scoped to that app's S3 bucket, DynamoDB tables, SSM secret namespace, etc. Per-developer access likewise scoped to the apps they're listed on — no account-wide grants.
- **TLS, DMARC `p=reject`, DKIM, SPF.** Anti-impersonation by default.

### Reasonable isolation between apps — not iron-clad

Apps share a single AWS account. Boundaries are enforced by IAM policies (per-resource ARNs and tags), not by account separation. They also share a single Neon Postgres project — each app gets its own database, but per-database isolation is at the SQL level, not the cluster level. The module defaults are correct; the platform doesn't *prevent* an app's TF from punching holes via custom inline policies.

### Deliberate trade-offs vs. enterprise

- **Long-lived static IAM access keys for developers.** No SSO permission sets, no AssumeRole, no MFA — chosen so non-developer users can be onboarded without console access. Compensated by per-app scoping and `gitleaks` pre-commit; mitigation is rotation, not prevention.
- **Cleartext secrets in Lambda env config.** Anyone with `lambda:GetFunctionConfiguration` on the app reads `DATABASE_URL`, your API keys, etc. (Same risk profile as the SSM-vended secrets the platform supports.)
- **TF state holds generated secrets.** Encrypted in S3, but anyone with S3 + KMS read on the state bucket has them.
- **Single region, no multi-region failover.** Region outage = platform outage.
- **No application-level audit logging, no compliance certifications, no third-party security audit.**

### Accepted compromises (revisit later)

Smaller concessions made for simplicity or to work around AWS-API quirks. Each is technical debt we know about but haven't paid down yet. Listed here so we don't forget.

- **CodeBuild log groups granted to devs with name-prefix scope, not tags.** CodeBuild auto-creates its log groups untagged on first build, so the dev policy's tag-based `CloudWatchLogs` statement can't match them. Worked around by granting `logs:Get*/Filter*/...LiveTail` on `arn:aws:logs:*:*:log-group:/aws/codebuild/<name_prefix>-*` unconditionally. Effect: dev `alice` can tail dev `bob`'s app's CodeBuild logs. Acceptable because build logs are build output (no runtime user data); fix path is to TF-manage the log groups so they get tags, and re-tighten the policy.
- **Pipeline service role granted whole-bucket access on the platform artifact bucket.** CodePipeline auto-generates its own paths (`<truncated-pipeline-name>/...`) under the shared artifact bucket — we don't control the prefix. Acceptable because CodePipeline isolates per-pipeline paths internally; theoretical risk is a compromised pipeline reading another pipeline's artifacts in the same bucket.
- **CloudWatch Logs Insights granted unconditionally.** `logs:StartQuery` requires `Resource: "*"` and tag conditions don't reliably scope across the log-group selection step. The downstream `GetLogEvents` calls *are* tag-scoped, so actual log content access is still bounded.
- **`logs:DescribeLogGroups` granted account-wide.** Required for log-group enumeration; tag conditions don't apply. Devs see log-group *names* across the account, but can't read log content unless the group is theirs.
- **Bedrock model invocation granted unconditionally.** Foundation-model ARNs are AWS-managed and untaggable. All devs can invoke any platform-published model regardless of which apps they're on. Mitigation: only Nova Lite is published (cheap), and bootstrap sets monthly budget alerts to catch runaway spend.
- **Pipeline triggers orchestrator on every push.** A push to an app repo causes the pipeline to call the orchestrator (admin-ish PowerUser) with the repo's `infra/` zip. Effect: a compromised repo can change AWS infra; the trust surface for "infra changes" is now `git push` access, same as `terraform apply` would be. Accepted to give devs the "git push does everything" UX. Mitigation path is a CloudFront-Function or Lambda@Edge layer that validates the zip before the orchestrator accepts it; not built.
- **AWS-managed CloudFront policy IDs hardcoded.** `aws_cloudfront_cache_policy` / `_origin_request_policy` data sources return null at plan time and produce "inconsistent final plan" errors during apply (provider bug). Hardcoded the constants instead. Brittle if AWS ever rotates these IDs (they shouldn't).
- **Yoyo migrations run on Lambda cold start.** Lambda's default 10-second timeout means any migration longer than that aborts mid-flight; Yoyo's advisory lock holds until the Postgres session dies. Accepted because migrations are meant to be fast (CLAUDE.md "Safe migration recipes"); a bigger refactor would split migrations into a separate one-off CodeBuild job.
- **Cloudflare origin-secret rotation is manual.** `random_password.origin_secret` is regenerated only when explicitly tainted, then both the WAF rule and Cloudflare Transform Rule update on next apply. No automatic rotation cadence.

### Use this for

- Internal tools, admin dashboards, ops pages.
- Rapid prototyping by a solo developer or small team.
- Apps where the worst-case breach is "embarrassing", not "company-killing".

### Don't use this for

- Anything subject to HIPAA, PCI-DSS, GDPR Article 9 (special-category data), or similar regulatory regimes.
- Multi-tenant SaaS where customer A's data must be account-isolated from customer B's.
- Customer-facing high-traffic production where one breach is existential.
- Payment processing, identity providers, healthcare records.

### Migration path when you outgrow it

The platform is designed to be torn down per-app cleanly. When an app graduates, the well-trodden upgrade path is: IAM Identity Center + permission sets + AssumeRole + MFA for developers, multi-account architecture (one AWS account per app or environment), SOC 2-grade logging (CloudTrail org trails, GuardDuty, Macie). None of that needs to be done up front.

---

## Architecture

```
                          ┌─────────────────────────┐
                          │  Browser                │
                          │  user@yourcompany.com   │
                          └────────────┬────────────┘
                                       │
                ┌──────────────────────▼──────────────────────┐
                │  Cloudflare Access (Email PIN auth)         │
                │  + Cloudflare Transform Rule (X-Origin-Sec) │
                └──────────────────────┬──────────────────────┘
                                       │
                ┌──────────────────────▼──────────────────────┐
                │  CloudFront + AWS WAFv2                      │
                │  (validates X-Origin-Secret, OAC SigV4-signs)│
                └──────────────────────┬──────────────────────┘
                                       │
                ┌──────────────────────▼──────────────────────┐
                │  Lambda Function URL  (auth_type = AWS_IAM) │
                │  FastAPI + Mangum, arm64 Graviton           │
                └──────────────────────┬──────────────────────┘
                                       │
            ┌──────────────────────────┴──────────────────────┐
            │                          │                      │
       ┌────▼─────┐             ┌──────▼──────┐        ┌──────▼──────┐
       │  Neon    │             │  S3 / DDB   │        │  Bedrock    │
       │ Postgres │             │  / SES      │        │  AI         │
       └──────────┘             └─────────────┘        └─────────────┘
```

Each app gets:
- A subdomain on your platform domain (`<app>.<platform-domain>`).
- Cloudflare Access auth — only emails/domains you allow can reach it.
- A trusted `Cf-Access-Authenticated-User-Email` header. App code reads it; no JWT validation, no auth library to vet.
- Optional: per-app Postgres role+database, S3 bucket, DynamoDB tables, SES email send, Bedrock model invoke, custom secrets via SSM.
- A CodePipeline that builds + deploys on every push.
- Per-developer AWS access scoped to just the apps they're listed on.

---

## Prerequisites

| Service | What you need | Why |
|---|---|---|
| **AWS account** | Admin access; one region for everything (`eu-central-1` by default) | Lambda, CloudFront, WAF, S3, DynamoDB, SSM, IAM, CodePipeline, CodeBuild, Bedrock, SES |
| **Cloudflare account** | An existing zone (your platform domain) + Zero Trust enabled (free tier works) | DNS, Access auth, Transform Rules |
| **Neon account** | An organisation (free tier supports the platform's shared project) | Postgres for apps |
| **GitHub or GitLab** | Account/org where app repos and this platform repo live | CodePipeline source via CodeConnections |
| **Terraform** | `>= 1.10` locally | To apply the bootstrap |

---

## Cost

- **Floor**: ~**$5/month** for the WAFv2 WebACL (one shared WebACL, hourly-charged regardless of traffic).
- **Everything else is usage-based** and within free tier for low-volume internal tools:
  - Lambda (free tier covers small apps)
  - CloudFront (1TB free per month)
  - S3 / DynamoDB / SSM (per-call, fractions of a cent at app scale)
  - SES (62,000 emails/mo free from Lambda)
  - Bedrock (pay per token; small for occasional LLM use)
  - CodePipeline ($1/active pipeline/month) + CodeBuild (per-build minutes)
  - Neon (free plan = 512 MB storage, 191 compute hours/mo)
  - Cloudflare Access free tier ≤ 50 users

For a typical solo-dev portfolio with a handful of low-traffic internal tools, expect **~$5–15/month** in AWS plus whichever Cloudflare/Neon plan you opt into.

---

## Layout

```
modules/
├── bootstrap/      # Apply ONCE per platform — creates tfstate bucket, SSM
│                     placeholders for credentials, WAF WebACL, Cloudflare
│                     Transform Rule for origin secret, SES identity (DKIM,
│                     SPF, DMARC), Neon project, CodeConnections, pipeline
│                     artifact bucket, response-header rules, cache rules.
│                     See modules/bootstrap/README.md.
│
├── quickship/      # Apply ONCE per app — creates Lambda, Function URL,
│                     CloudFront distribution, OAC, Cloudflare Access app +
│                     DNS, optional Neon role+database, S3 bucket, DynamoDB
│                     tables, SES grant, Bedrock grant, SSM secret
│                     placeholders, CodePipeline. Reads platform facts from
│                     SSM published by `bootstrap`. See modules/quickship/README.md.
│
└── developer/      # Apply ONCE per developer — creates an IAM user. Per-app
                      permissions are attached as managed policies by
                      `quickship` modules whose `developers` input names them.
                      See modules/developer/README.md.
```

---

## Setup walkthrough

The whole thing takes ~30 minutes the first time, mostly waiting for CloudFront and DNS.

### 1. Decide where this platform lives

- One AWS account.
- One Cloudflare zone (`apps.example.com` or whatever).
- Pick a `name_prefix` (e.g., `quickship`). All resources will be tagged and named with it.

### 2. Create your consumer Terraform repo

This is **not** this repo. It's a separate (typically private) repo that holds your `terraform apply`-able root module. It calls the modules in this repo:

```hcl
# accounts/prod/tinyapp.tf  (in your consumer repo, not here)

module "platform_bootstrap" {
  source = "git::https://github.com/stadskle/quickship-app-platform.git//modules/bootstrap?ref=main"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix     = "quickship"
  platform_source = "github.com/stadskle/quickship-app-platform"
  domain          = "apps.example.com"
  email_enabled   = true
  git_connection_providers = ["GitHub"]   # or ["GitLab"]
}

module "alice" {
  source = "git::https://github.com/stadskle/quickship-app-platform.git//modules/developer?ref=main"
  name   = "alice"
}
```

(See `modules/bootstrap/README.md` and `modules/developer/README.md` for the full input list and chicken-and-egg first-apply procedure.)

### 3. First `terraform apply`

The bootstrap module's first apply will fail partway through — Cloudflare provider needs credentials, but those credentials are stored in SSM placeholders that don't exist yet. Procedure documented in detail in `modules/bootstrap/README.md`. Short version:

1. `terraform apply -target=module.platform_bootstrap.aws_ssm_parameter.cloudflare_*` (creates placeholders).
2. Populate placeholder values via the AWS console (one-time).
3. `terraform apply` (full apply now succeeds).
4. Finalize Cloudflare and CodeConnections handshakes in their respective consoles (one-time).

### 4. Onboard each developer

For every person who'll deploy or debug an app:

```hcl
module "alice" {
  source = "git::https://github.com/stadskle/quickship-app-platform.git//modules/developer?ref=main"
  name   = "alice"
}
```

Apply, then mint an access key:
```bash
aws iam create-access-key --user-name quickship-developer-alice
```

Send the access key + secret to alice over a secure channel. She runs `aws configure --profile quickship` once on her machine and she's done. Walkthrough in `modules/developer/README.md`.

### 5. Each new app

The end-developer (alice) clones [quickship-app-template](https://github.com/stadskle/quickship-app-template), runs `./bootstrap.sh`, and starts talking to Claude. The template's `bootstrap.sh` reads platform facts from SSM (account ID, region, this repo's URL) and substitutes them into the new app's Terraform — alice never types this repo's URL or your account ID.

---

## Module READMEs

- [`modules/bootstrap`](./modules/bootstrap/README.md) — platform-level resources.
- [`modules/quickship`](./modules/quickship/README.md) — per-app resources.
- [`modules/developer`](./modules/developer/README.md) — per-developer IAM.

---

## Forking / using this without me

The defaults in `modules/bootstrap/variables.tf` reference `github.com/stadskle/quickship-app-platform` for `platform_source`. If you fork this repo and use it as your own platform's modules, override that input in your bootstrap call to point at your fork. Everything else is generic.

---

## Pre-commit hooks

The repo has a `.pre-commit-config.yaml` with [gitleaks](https://github.com/gitleaks/gitleaks) — catches accidental commits of `AKIA…` access keys and similar secret patterns. Once after cloning:

```bash
brew install pre-commit
pre-commit install
```

Now every `git commit` runs gitleaks first.
