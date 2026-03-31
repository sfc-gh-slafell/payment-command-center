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

## Issue 6 — `003001: Insufficient privileges to operate on schema 'SERVE'` (schemachange V1.2.0)

**Symptom:** schemachange migration `V1.2.0__create_interactive_tables.sql` failed with:
```
003001 (42501): Insufficient privileges to operate on schema 'SERVE'
```

**Root cause:** `CREATE INTERACTIVE TABLE` is a **separate privilege** from `CREATE TABLE` in Snowflake. `PAYMENTS_ADMIN_ROLE` had `CREATE TABLE` on the `SERVE` schema but not `CREATE INTERACTIVE TABLE`. The two privileges are distinct and must both be granted.

**Fix:** Added `"CREATE INTERACTIVE TABLE"` to the `admin_schema_serve` grant in `terraform/grants.tf`:

```hcl
resource "snowflake_grant_privileges_to_account_role" "admin_schema_serve" {
  account_role_name = snowflake_account_role.payments_admin.name
  privileges        = ["USAGE", "CREATE TABLE", "CREATE INTERACTIVE TABLE", "CREATE DYNAMIC TABLE"]
  on_schema {
    schema_name = snowflake_schema.serve.fully_qualified_name
  }
}
```

**Note:** Interactive Tables are Dynamic Tables internally. `SHOW INTERACTIVE TABLES` reveals `create OR REPLACE dynamic table` in the `text` column. `CREATE INTERACTIVE TABLE` and `CREATE DYNAMIC TABLE` are both needed for full forward-compatibility.

---

## Issue 7 — `001003: syntax error` in schemachange V1.3.0 (invalid DDL for interactive warehouse)

**Symptom (attempt 1):** Migration `V1.3.0__create_interactive_warehouse_table_assoc.sql` failed with:
```
001003: SQL compilation error: syntax error unexpected 'TABLES'
```
The offending SQL was: `ALTER WAREHOUSE PAYMENTS_INTERACTIVE_WH SET TABLES = (...)`

**Root cause:** No such syntax exists. Interactive Tables do not need to be explicitly associated with an Interactive Warehouse via a `SET TABLES` clause. They use the Interactive Warehouse automatically for serving queries.

**Fix — attempt 1:** Changed to `ALTER INTERACTIVE WAREHOUSE PAYMENTS_INTERACTIVE_WH ...`

**Symptom (attempt 2):** Still failed with:
```
001003: SQL compilation error: syntax error unexpected 'WAREHOUSE'
```

**Root cause:** `ALTER INTERACTIVE WAREHOUSE` is also not valid Snowflake SQL. Interactive Warehouses are managed via standard `ALTER WAREHOUSE` syntax. Verified by running directly in Snowflake worksheet.

**Side effect discovered:** During debugging, `ALTER INTERACTIVE TABLE PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS SET WAREHOUSE = PAYMENTS_INTERACTIVE_WH` was accidentally run, changing the *refresh* warehouse from `PAYMENTS_REFRESH_WH` to `PAYMENTS_INTERACTIVE_WH`. Fixed immediately:
```sql
ALTER INTERACTIVE TABLE PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS
  SET WAREHOUSE = PAYMENTS_REFRESH_WH;
```

**Final fix:** Reduced V1.3.0 to only what is needed — resume the warehouse if suspended. No explicit table-to-warehouse association DDL exists or is needed:

```sql
-- Interactive tables automatically use the interactive warehouse for serving.
-- No explicit association DDL is required or valid in Snowflake.
ALTER WAREHOUSE PAYMENTS_INTERACTIVE_WH RESUME IF SUSPENDED;
```

---

## Issue 8 — `SNOWFLAKE_ACCOUNT` env var empty across all jobs (dbt, schemachange, snow CLI)

**Symptom:** Multiple jobs failed with account-related errors:
- dbt: `251001: Account must be specified`
- snow CLI: `251001: Account must be specified`

**Root cause:** The top-level workflow env had:
```yaml
env:
  SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
```
The secret `SNOWFLAKE_ACCOUNT` does not exist — only `SNOWFLAKE_ORGANIZATION_NAME` and `SNOWFLAKE_ACCOUNT_NAME` are defined. GitHub Actions evaluates a missing secret as an empty string, so every job inherited `SNOWFLAKE_ACCOUNT=""`.

**Fix:** Override `SNOWFLAKE_ACCOUNT` at the **job level** using `format()` to combine the two secrets:

```yaml
jobs:
  dbt-run:
    env:
      SNOWFLAKE_ACCOUNT: ${{ format('{0}-{1}', secrets.SNOWFLAKE_ORGANIZATION_NAME, secrets.SNOWFLAKE_ACCOUNT_NAME) }}

  docker-push:
    env:
      SNOWFLAKE_ACCOUNT: ${{ format('{0}-{1}', secrets.SNOWFLAKE_ORGANIZATION_NAME, secrets.SNOWFLAKE_ACCOUNT_NAME) }}

  spcs-deploy:
    env:
      SNOWFLAKE_ACCOUNT: ${{ format('{0}-{1}', secrets.SNOWFLAKE_ORGANIZATION_NAME, secrets.SNOWFLAKE_ACCOUNT_NAME) }}
```

For schemachange, pass directly in the step env:
```yaml
env:
  SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ORGANIZATION_NAME }}-${{ secrets.SNOWFLAKE_ACCOUNT_NAME }}
```

---

## Issue 9 — `snow CLI connections.toml`: `organization_name`/`account_name` keys not recognised

**Symptom:** `snow spcs image-registry login` failed with a connection error despite `connections.toml` being present.

**Root cause:** The `connections.toml` was written with separate `organization_name` and `account_name` fields. The Snowflake CLI expects the **combined** `account` field in `org-account` format.

**Fix:**
```toml
[default]
account = "SFPSCOGS-SLAFELL_AWS_2"   # combined org-account, not separate fields
user = "SLAFELL"
authenticator = "SNOWFLAKE_JWT"
private_key_path = "/tmp/snowflake_key.p8"
```

Also: `connections.toml` must be `chmod 0600` or the CLI rejects it with a permissions error.

---

## Issue 10 — `docker/setup-buildx-action@v3` isolated builder has no host credentials

**Symptom:** `docker buildx build --push` failed with `401 Unauthorized`.

**Root cause:** `docker/setup-buildx-action@v3` creates a builder using the `docker-container` driver, which runs in an isolated container with its own filesystem. It cannot access the host's `~/.docker/config.json`, so credentials stored by `snow spcs image-registry login` are invisible to it.

**Fix:** Removed `docker/setup-buildx-action@v3` entirely. The default `docker` driver (built into the Docker daemon) shares the host credential store.

---

## Issue 11 — `Get "https:/v2/": http: no Host in request URL` (Docker underscore hostname)

**Symptom:** `docker push sfpscogs-slafell_aws_2.registry.snowflakecomputing.com/...` failed with:
```
Get "https:/v2/": http: no Host in request URL
```

**Root cause:** Docker's legacy distribution library uses Go's `net/url.Parse()` for registry URL construction. Go's URL parser rejects hostnames containing underscores per RFC 1123 (which permits only letters, digits, and hyphens in hostname labels). When the hostname is invalid, `url.Parse()` returns an empty `Host` field, and Docker constructs a malformed URL `https:/v2/` (single slash, no host).

**Fix:** `snow spcs image-registry login` normalises the account identifier when calling `docker login` — it lowercases the entire string **and replaces underscores with hyphens**. The credential is therefore stored under `sfpscogs-slafell-aws-2.registry.snowflakecomputing.com` (RFC-compliant, all hyphens).

The push hostname must match this. Compute `REGISTRY` in the workflow by applying the same normalisation:

```yaml
- name: Compute RFC-compliant registry hostname
  run: |
    REGISTRY=$(echo "${{ secrets.SNOWFLAKE_ORGANIZATION_NAME }}-${{ secrets.SNOWFLAKE_ACCOUNT_NAME }}" \
      | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    echo "REGISTRY=${REGISTRY}.registry.snowflakecomputing.com" >> "$GITHUB_ENV"
```

This resolves **both** the URL parsing failure and the credential key mismatch in one change, with no need for containerd-snapshotter workarounds.

**Diagnosis method:** Added a debug step after `snow spcs image-registry login` to dump `~/.docker/config.json` auth keys:
```yaml
python3 -c "import json,sys; cfg=json.load(open('/home/runner/.docker/config.json')); \
  print('Auth keys:', [k for k in cfg.get('auths', {})])"
```
Output revealed: `Auth keys: ['sfpscogs-slafell-aws-2.registry.snowflakecomputing.com']` — hyphens, not underscores.

---

## Issue 12 — `003001: Insufficient privileges to operate on schema 'APP'` (SPCS service create)

**Symptom:** `snow spcs service create` failed with:
```
003001 (42501): Insufficient privileges to operate on schema 'APP'
```

**Root cause:** `PAYMENTS_APP_ROLE` had only `USAGE` on the `APP` schema. `CREATE SERVICE` is a separate privilege that must be granted explicitly, similar to `CREATE TABLE` or `CREATE STAGE`.

**Fix:** Added `"CREATE SERVICE"` to the `app_schema_app` grant in `terraform/grants.tf`:

```hcl
resource "snowflake_grant_privileges_to_account_role" "app_schema_app" {
  account_role_name = snowflake_account_role.payments_app.name
  privileges        = ["USAGE", "CREATE SERVICE"]
  on_schema {
    schema_name = snowflake_schema.app.fully_qualified_name
  }
}
```

---

## Issue 13 — `395018: Invalid spec: unknown option 'serviceRoles'`

**Symptom:** `snow spcs service create` failed with:
```
395018 (22023): Invalid spec: unknown option 'serviceRoles' for 'spec'
```

**Root cause:** The `serviceRoles` field in `spcs/service_spec.yaml` is not supported in this Snowflake account's SPCS version.

**Fix:** Removed the `serviceRoles` block from the service spec. The `dashboard` endpoint remains accessible via `public: true`:

```yaml
endpoints:
  - name: dashboard
    port: 8080
    public: true
```

---

## Issue 14 — `002003: Image repository 'PAYMENTS_DB.APP.DASHBOARD_REPO' does not exist or not authorized`

**Symptom:** `snow spcs service create` failed with:
```
002003: SQL compilation error: Image repository 'PAYMENTS_DB.APP.DASHBOARD_REPO'
does not exist or not authorized.
```

**Root cause:** Snowflake validates the image reference in the service spec at `CREATE SERVICE` time. `PAYMENTS_APP_ROLE` had no `READ` privilege on the `DASHBOARD_REPO` image repository, so Snowflake treats it as non-existent from that role's perspective.

**Fix:** Added a `snowflake_execute` grant in `terraform/stages.tf` with `depends_on` the repository creation:

```hcl
resource "snowflake_execute" "grant_repo_read_to_app_role" {
  execute = "GRANT READ ON IMAGE REPOSITORY \"${snowflake_database.payments_db.name}\".\"${snowflake_schema.app.name}\".\"DASHBOARD_REPO\" TO ROLE PAYMENTS_APP_ROLE"
  revert  = "REVOKE READ ON IMAGE REPOSITORY \"${snowflake_database.payments_db.name}\".\"${snowflake_schema.app.name}\".\"DASHBOARD_REPO\" FROM ROLE PAYMENTS_APP_ROLE"
  query   = "SHOW GRANTS ON IMAGE REPOSITORY \"${snowflake_database.payments_db.name}\".\"${snowflake_schema.app.name}\".\"DASHBOARD_REPO\""
  depends_on = [snowflake_execute.dashboard_repo]
}
```

---

## Issue 15 — PAYMENTS_APP_ROLE missing USAGE on compute pool

**Root cause (pre-emptive fix):** `CREATE SERVICE` requires `USAGE` on the compute pool used by the service. No grant existed for `PAYMENTS_APP_ROLE` on `PAYMENTS_DASHBOARD_POOL`. This was added alongside Issue 12 to avoid a sequential failure.

**Fix:** Added a `snowflake_execute` grant in `terraform/compute_pools.tf`:

```hcl
resource "snowflake_execute" "grant_pool_to_app_role" {
  execute    = "GRANT USAGE ON COMPUTE POOL PAYMENTS_DASHBOARD_POOL TO ROLE PAYMENTS_APP_ROLE"
  revert     = "REVOKE USAGE ON COMPUTE POOL PAYMENTS_DASHBOARD_POOL FROM ROLE PAYMENTS_APP_ROLE"
  query      = "SHOW GRANTS ON COMPUTE POOL PAYMENTS_DASHBOARD_POOL"
  depends_on = [snowflake_execute.payments_dashboard_pool]
}
```

---

## First fully green run

**Run:** [23776979677](https://github.com/sfc-gh-slafell/payment-command-center/actions/runs/23776979677)

All 6 jobs passed in a single execution:

| Job | Duration | Status |
|-----|----------|--------|
| 1. Terraform Apply | 23s | ✓ |
| 2. schemachange Deploy | 21s | ✓ |
| 3. dbt Run + Test | 37s | ✓ |
| 4. Docker Build + Push | 10m13s | ✓ |
| 5. SPCS Service Deploy | 26s | ✓ |
| 6. Kafka Connector Deploy | 3s | ✓ |

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

---

## Issue 16 — Service stuck `PENDING` / `"Readiness probe is failing"` after ARM image push

**Symptom:** `SYSTEM$GET_SERVICE_STATUS` reports `PENDING` with `"Readiness probe is failing at path: /health, port: 8080"` indefinitely. Container logs show `GET /health HTTP/1.1" 200 OK` on every probe. Ingress returns `"no service hosts found"`.

**Root cause:** The `:latest` image tag in the registry was overwritten by a local build on an Apple Silicon (ARM) Mac without `--platform linux/amd64`. SPCS only supports `amd64` images. The container can start (from the cached pull on the node) and respond to HTTP probes, but SPCS's orchestration layer detects the architecture mismatch and never transitions the pod to `READY`, blocking ingress routing.

Confirmed by attempting `ALTER SERVICE ... FROM SPECIFICATION` which triggers a fresh image pull validation:
```
Failed to retrieve image: SPCS only supports image for amd64 architecture.
Please rebuild your image with '--platform linux/amd64' option.
```

**Fix:** Added `--platform linux/amd64` to both `docker build` commands in `.github/workflows/deploy.yml`:

```yaml
docker build --platform linux/amd64 -f app/Dockerfile app/ ...
docker build --platform linux/amd64 -f generator/Dockerfile generator/ ...
```

**Prevention:** Never push images to the SPCS registry from an ARM Mac without `--platform linux/amd64`. All production builds should go through the GitHub Actions workflow (which runs on `ubuntu-latest` / AMD64), not from a local machine.

---

## Issue 17 — `snow spcs service create` fails on re-deploy (service already exists)

**Symptom:** Re-running the deploy workflow after the first green run causes job 5 (SPCS Service Deploy) to fail because `snow spcs service create` errors if the named service already exists.

**Root cause:** `snow spcs service create` is not idempotent — it fails if the service already exists with no `--if-not-exists` flag available.

**Fix:** Changed the deploy step to attempt `upgrade` first (idempotent — updates spec and restarts pods), falling back to `create` only if the service doesn't exist yet:

```yaml
- name: Deploy SPCS service
  run: |
    snow spcs service upgrade PAYMENT_DASHBOARD --spec-path spcs/service_spec.yaml --database PAYMENTS_DB --schema APP \
      || snow spcs service create PAYMENT_DASHBOARD --spec-path spcs/service_spec.yaml --compute-pool PAYMENTS_DASHBOARD_POOL --database PAYMENTS_DB --schema APP
```
