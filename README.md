# quickship platform

Infrastructure-as-code (Terraform modules) for the **quickship** internal-developer-platform: a tiny, opinionated stack that lets non-developers ship small SaaS-style internal tools by talking to Claude.

This repo is the **platform side** — the modules a platform admin applies once to set up the shared AWS + Cloudflare + Neon plumbing, plus a per-app module that each new app's `infra/` calls. The companion **app template** lives at [stadskle/quickship-app-template](https://github.com/stadskle/quickship-app-template).

> **Audience**: you're setting up a quickship platform for yourself or a small team. You're comfortable with Terraform, AWS, and reading module READMEs. The end users of *apps* you'll later build don't need any of that.

---

## What you get

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

module "ketil" {
  source = "git::https://github.com/stadskle/quickship-app-platform.git//modules/developer?ref=main"
  name   = "ketil"
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
