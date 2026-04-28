# developer

Provisions one developer's IAM identity for the quickship platform: a single IAM user. Per-app permissions are attached to the user by `quickship` modules that name this developer in their `developers` input, so onboarding once gives multi-app access automatically.

## What this module does — and deliberately doesn't do

| Concern | Approach |
|---|---|
| IAM user creation | ✅ Terraform |
| Access keys | ❌ NOT in Terraform — admin runs `aws iam create-access-key` after apply, captures from CLI output. Keeps secrets out of TF state. |
| MFA | ❌ Not used. The target audience (non-developer users of Claude-built apps) doesn't have AWS console access, so MFA-device QR-scan setup isn't viable. |
| Permissions | ❌ Not in this module. Each `quickship` module call lists `developers = [...]` and attaches a per-app managed policy to the named user. |

The trade-off (vs. a stricter AssumeRole-with-MFA design): leaked access keys grant full per-app access until rotated. Mitigations:

- **Rotate periodically.** `aws iam create-access-key` then `aws iam delete-access-key` on the old. No TF apply needed.
- **`gitleaks` (or similar) pre-commit hook.** Catches accidental commits of `AKIA…` patterns. The biggest practical leak vector.
- **No console session is granted.** This user has only programmatic access; there's no password to brute-force.

If you need stricter-than-this for a particular environment, AWS IAM Identity Center (with permission sets and SSO) is the right substitute — at much higher setup cost.

---

## Usage

In the consuming Terraform repo (the platform admin's `infrastructure-as-code` repo, alongside `bootstrap` and `quickship` calls):

```hcl
module "alice" {
  source = "git::https://<host>/<owner>/ai-apps-platform.git//modules/developer?ref=<tag>"
  name   = "alice"
}

module "bob" {
  source = "git::https://<host>/<owner>/ai-apps-platform.git//modules/developer?ref=<tag>"
  name   = "bob"
}
```

In each `quickship` call, list the developers who can debug/operate that app:

```hcl
module "hello_world" {
  source = "git::.../modules/quickship?ref=<tag>"

  app_name           = "hello-world"
  developers         = ["alice", "bob"]
  # ... rest
}
```

Tinyapp creates a managed policy per app and attaches it to each named user.

---

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | – | Short identifier (`alice`, `bob`). 2-32 chars, lowercase letters/digits/hyphens. |
| `name_prefix` | string | `"quickship"` | Should match bootstrap's `name_prefix`. |
| `tags` | map(string) | `{}` | Extra tags. |

## Outputs

| Name | Description |
|---|---|
| `user_name` | IAM user name (used by `quickship` to attach per-app policies). |
| `user_arn` | IAM user ARN. |
| `create_access_key_command` | The `aws iam create-access-key …` command for the admin to run post-apply. |
| `developer_setup_command` | The `aws configure --profile …` command for the developer to run on their machine. |

---

## Onboarding walkthrough

After `terraform apply`, here's what to do in order.

### 1. Mint an access key (admin, on CLI)

```bash
terraform output -raw alice_create_access_key_command | bash
```

(Where `alice_create_access_key_command` is whatever output you've exposed at the platform-repo top level — see the platform repo's `outputs.tf` for the per-developer plumbing.)

The CLI prints something like:

```json
{
  "AccessKey": {
    "UserName": "quickship-developer-alice",
    "AccessKeyId": "AKIA…",
    "SecretAccessKey": "…",
    "Status": "Active",
    "CreateDate": "…"
  }
}
```

**Capture the `AccessKeyId` and `SecretAccessKey`**. They're shown ONCE here — AWS won't let you re-fetch the secret later.

### 2. Hand the keys to the developer (secure channel)

1Password, Bitwarden Send, Signal disappearing message — anything that doesn't write the secret to email/Slack DMs/files-on-disk. Tell the developer the profile name to use (defaults to `quickship`, or `<name_prefix>` if customised).

### 3. Developer-side: configure the profile

```bash
aws configure --profile quickship
```

Paste the access key when prompted; paste the secret. Region: whichever the platform runs in (usually `eu-central-1`). Output: `json`.

### 4. Verify

```bash
aws sts get-caller-identity --profile quickship
```

Output `Arn` ends with `user/quickship-developer-alice`. Done.

The developer can now run any platform CLI recipe (`/deploy`, log tails, etc.) using `aws --profile quickship …`.

---

## Adding the developer to a new app

In the app's `quickship` call, append the name to `developers`:

```hcl
developers = ["alice", "bob"]  # was ["alice"]
```

`terraform apply` attaches the new app's managed policy to bob's IAM user. Bob's access key, profile, etc. don't change — he just has more permissions on the next API call.

## Removing access from one app

Drop the name from that app's `developers` list and apply. The managed policy attachment is removed; future API calls fail authorization. The developer's access key is unchanged.

## Permanent offboarding

1. Drop the developer from every `quickship` call's `developers` list.
2. Delete the access key:
   ```bash
   aws iam list-access-keys --user-name quickship-developer-<name>
   aws iam delete-access-key --user-name quickship-developer-<name> --access-key-id <id>
   ```
3. Remove the `module "<name>"` block from the platform repo and `terraform apply`. This deletes the IAM user.

## Rotation

Every 90 days (or per your org's policy):

```bash
# Create the new key
aws iam create-access-key --user-name quickship-developer-alice
# (capture new keys, send to alice over secure channel)
# alice runs `aws configure --profile quickship` and pastes the new keys

# Delete the old key (find its ID first)
aws iam list-access-keys --user-name quickship-developer-alice
aws iam delete-access-key --user-name quickship-developer-alice --access-key-id <OLD_ID>
```

AWS allows two simultaneous access keys per user, so you can mint the new one before retiring the old — gives a transition window where alice can update her local config without downtime.
