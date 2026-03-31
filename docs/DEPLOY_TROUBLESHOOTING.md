# Deploy Workflow — Troubleshooting Log

Authoritative record of every CI/CD failure encountered during initial deployment,
root cause analysis, and the fix applied. Ordered chronologically.

---

## Issue 1 — Terraform hung indefinitely in GitHub Actions

**Symptom:** `terraform apply` step ran for 1+ hour with no output, then was cancelled manually.

**Root cause:** Two missing/mismatched Terraform input variables caused an interactive prompt:
- `TF_VAR_snowflake_account` was set, but `terraform/variables.tf` declared `var.snowflake_account_name` — name mismatch, Terraform prompted for the value
- `TF_VAR_snowflake_organization_name` was missing entirely — second interactive prompt

Because GitHub Actions has no stdin, Terraform waited forever for input.

**Fix:**
- Corrected env var names in `.github/workflows/deploy.yml` to match `variables.tf` exactly
- Added missing `TF_VAR_snowflake_organization_name`
- Added `-input=false` to `terraform apply` to fail fast instead of hanging
- Changed workflow trigger from `push: branches: [main]` to `workflow_dispatch`

```yaml
env:
  TF_VAR_snowflake_organization_name: ${{ secrets.SNOWFLAKE_ORGANIZATION_NAME }}
  TF_VAR_snowflake_account_name: ${{ secrets.SNOWFLAKE_ACCOUNT_NAME }}
  TF_VAR_snowflake_user: ${{ secrets.SNOWFLAKE_USER }}
```

---

## Issue 2 — `260001: user is empty`

**Symptom:** Terraform apply failed immediately with `260001: user is empty`.

**Root cause:** GitHub Actions secrets `SNOWFLAKE_USER` and `SNOWFLAKE_PRIVATE_KEY` had not been added to the repository.

**Fix:** Added the following secrets to the GitHub repository (`Settings → Secrets → Actions`):
- `SNOWFLAKE_USER` = `SLAFELL`
- `SNOWFLAKE_PRIVATE_KEY` = RSA private key content (PKCS8 PEM, generated below)

**Generating the RSA key pair:**
```bash
# Generate PKCS8 unencrypted private key
openssl genrsa 2048 | openssl pkcs8 -topk8 -nocrypt -out /tmp/snowflake.p8

# Extract public key
openssl rsa -in /tmp/snowflake.p8 -pubout -out /tmp/snowflake_pub.pem

# Apply public key to Snowflake user
# (strip PEM headers, run in Snowflake)
ALTER USER SLAFELL SET RSA_PUBLIC_KEY = '<base64-body-only>';

# Copy private key to clipboard for GitHub secret
cat /tmp/snowflake.p8 | pbcopy
```

---

## Issue 3 — `260002: password is empty`

**Symptom:** Terraform connect failed with `260002: password is empty` even after `SNOWFLAKE_PRIVATE_KEY` secret was added.

**Root cause — attempt 1:** `SNOWFLAKE_PRIVATE_KEY` env var was set at the job level, but the Snowflake TF provider v2.x does not automatically read it without an explicit `private_key` attribute in the provider block. The provider fell back to password auth and errored.

**Fix — attempt 1:** Added `SNOWFLAKE_PRIVATE_KEY: ${{ secrets.SNOWFLAKE_PRIVATE_KEY }}` to the terraform job env. **Did not resolve** — env var alone is insufficient without the provider block attribute.

**Root cause — attempt 2 (actual):** The provider block in `terraform/main.tf` had no `private_key` attribute. Without it, the provider ignores the env var and defaults to password authentication regardless.

**Fix — attempt 2:** Added `private_key = var.snowflake_private_key` to the provider block, and passed the key content via `TF_VAR_snowflake_private_key`.

**Root cause — attempt 3 (final):** Even with `private_key` set, the provider still tried password auth because `authenticator` was not specified. Per the [official docs](https://registry.terraform.io/providers/snowflakedb/snowflake/latest/docs), key-pair auth requires `authenticator = "SNOWFLAKE_JWT"` explicitly.

**Fix — attempt 3 (final):** Added `authenticator = "SNOWFLAKE_JWT"` to the provider block.

```hcl
provider "snowflake" {
  organization_name = var.snowflake_organization_name
  account_name      = var.snowflake_account_name
  user              = var.snowflake_user
  role              = var.snowflake_role
  authenticator     = "SNOWFLAKE_JWT"
  private_key       = var.snowflake_private_key
}
```

`terraform/variables.tf` addition:
```hcl
variable "snowflake_private_key" {
  type      = string
  sensitive = true
}
```

`.github/workflows/deploy.yml` terraform job env:
```yaml
TF_VAR_snowflake_private_key: ${{ secrets.SNOWFLAKE_PRIVATE_KEY }}
```

---

## Issue 4 — `390422: IP not allowed` (GitHub Actions runner blocked)

**Symptom:** Terraform authenticated successfully but the connection was immediately rejected with:
```
390422: Incoming request with IP 64.236.133.98 is not allowed to access Snowflake.
```

**Root cause:** The account has network policy `ACCOUNT_VPN_POLICY_SE` (99-entry allowlist) applied at account level. GitHub Actions runners use dynamic IPs from a pool of 4,726+ IPv4 CIDRs — none were in the allowlist.

**Fix:** Created a user-level network policy for `SLAFELL` that allows all GitHub Actions CIDRs plus personal access IPs, overriding the account-level policy for this user only.

```bash
# Fetch GitHub Actions IP ranges
curl -s https://api.github.com/meta | python3 -c "
import json, sys
d = json.load(sys.stdin)
cidrs = [c for c in d.get('actions', []) if ':' not in c]  # IPv4 only
"

# Due to Snowflake's 10,000-entry limit per rule, split across 3 rules of ~1,600 each
# Rules created in MISC.PUBLIC (existing DB with ACCOUNTADMIN ownership):
#   MISC.PUBLIC.SLAFELL_CICD_RULE_1  (entries 1-1600)
#   MISC.PUBLIC.SLAFELL_CICD_RULE_2  (entries 1601-3200)
#   MISC.PUBLIC.SLAFELL_CICD_RULE_3  (entries 3201-4731, includes personal IPs)

CREATE OR REPLACE NETWORK POLICY SLAFELL_CICD_POLICY
    ALLOWED_NETWORK_RULE_LIST = (
        'MISC.PUBLIC.SLAFELL_CICD_RULE_1',
        'MISC.PUBLIC.SLAFELL_CICD_RULE_2',
        'MISC.PUBLIC.SLAFELL_CICD_RULE_3'
    );

ALTER USER SLAFELL SET NETWORK_POLICY = SLAFELL_CICD_POLICY;
```

**Note:** GitHub Actions IPs change periodically. To refresh the network rules, re-run the Python generation script and recreate the rules. Personal IPs included: `135.232.200.211`, `162.224.116.244`, `38.32.156.142`, `13.78.133.23`, `52.161.104.33`.

---

## Issue 5 — `003001: Insufficient privileges` on resource monitor + preview feature flag

**Symptom:** Terraform apply reached resource creation but failed with two simultaneous errors:

```
003001 (42501): Insufficient privileges to operate on account 'FNB70636'.
  with snowflake_resource_monitor.payments_monitor

snowflake_stage_internal_resource is currently a preview feature, and must be
enabled by adding snowflake_stage_internal_resource to `preview_features_enabled`.
  with snowflake_stage_internal.specs
```

**Root cause 1:** `snowflake_resource_monitor` requires `ACCOUNTADMIN` role. The provider was configured with default role `SYSADMIN`.

**Fix 1:** Changed default value of `var.snowflake_role` in `terraform/variables.tf` from `"SYSADMIN"` to `"ACCOUNTADMIN"`. Resource monitors, compute pools, and image repositories all require ACCOUNTADMIN.

**Root cause 2:** `snowflake_stage_internal` is a preview resource in TF provider v2.x and must be explicitly opted into.

**Fix 2:** Added `preview_features_enabled` to the provider block in `terraform/main.tf`:

```hcl
provider "snowflake" {
  # ... existing config ...
  preview_features_enabled = ["snowflake_stage_internal_resource"]
}
```

---

## Required GitHub Actions Secrets

| Secret | Value | Notes |
|--------|-------|-------|
| `SNOWFLAKE_ORGANIZATION_NAME` | `SFPSCOGS` | From `SELECT CURRENT_ORGANIZATION_NAME()` |
| `SNOWFLAKE_ACCOUNT_NAME` | `SLAFELL_AWS_2` | From `SELECT CURRENT_ACCOUNT_NAME()` |
| `SNOWFLAKE_USER` | `SLAFELL` | Snowflake username |
| `SNOWFLAKE_PRIVATE_KEY` | Full PKCS8 PEM content | Including `-----BEGIN/END PRIVATE KEY-----` headers |

## Snowflake Queries to Retrieve Account Values

```sql
SELECT CURRENT_ORGANIZATION_NAME();  -- SFPSCOGS
SELECT CURRENT_ACCOUNT_NAME();       -- SLAFELL_AWS_2
SELECT CURRENT_USER();               -- SLAFELL
```
