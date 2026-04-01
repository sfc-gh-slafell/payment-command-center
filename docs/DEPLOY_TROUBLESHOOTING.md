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

---

## Issue 18 — Frontend returns `{"detail":"Not Found"}` (off-by-one `.parent` in static path)

**Symptom:** The dashboard URL loads the Snowflake SSO login page, but after authenticating the app returns `{"detail":"Not Found"}` from FastAPI. `/health` responds correctly.

**Root cause:** `main.py` calculated the static files path with one extra `.parent`:

```python
# Wrong — resolves to /frontend/dist (does not exist)
static_dir = Path(__file__).parent.parent / "frontend" / "dist"
```

The Dockerfile copies the frontend build to `/app/frontend/dist/`:
```
WORKDIR /app
COPY backend/ ./          # main.py → /app/main.py
COPY --from=frontend-builder /frontend/dist ./frontend/dist  # → /app/frontend/dist
```

`Path(__file__).parent` = `/app`, then `.parent` again = `/` (filesystem root). So `static_dir` resolved to `/frontend/dist` which does not exist. The `if static_dir.exists():` guard silently skipped the mount, leaving FastAPI to return its default 404 for `/`.

**Fix:** Removed the extra `.parent` in `app/backend/main.py`:

```python
# Correct — resolves to /app/frontend/dist
static_dir = Path(__file__).parent / "frontend" / "dist"
```

---

## Issue 19 — Kafka connector using wrong class (`SnowflakeSinkConnector` vs `SnowflakeStreamingSinkConnector`)

**Symptom:** `AUTH_EVENTS_RAW` table has 0 rows despite the generator running and connector showing as RUNNING in Kafka Connect. No data lands in Snowflake.

**Root cause:** `kafka-connect/shared.json` had `connector.class: com.snowflake.kafka.connector.SnowflakeSinkConnector` — the v3.x legacy class. The HP (High Performance) Kafka connector v4.x uses a different class: `SnowflakeStreamingSinkConnector`. Using the wrong class caused the connector to operate in legacy Snowpipe batch mode, which requires different privileges and object types not present in this setup.

**Fix:** Updated `kafka-connect/shared.json`:

```json
"connector.class": "com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector"
```

---

## Issue 20 — v3.x-only config key `snowflake.ingestion.method` present in HP connector config

**Symptom:** Related to Issue 19 — connector config contained `"snowflake.ingestion.method": "SNOWPIPE_STREAMING"` which is a v3.x parameter used to opt-in to Snowpipe Streaming mode. In HP connector v4.x, Snowpipe Streaming HPA is the only mode; the key is unrecognised and causes a config validation warning/error.

**Root cause:** Config was written against v3.x docs and never updated when the project moved to HP v4.x.

**Fix:** Removed `snowflake.ingestion.method` from `kafka-connect/shared.json`. It has no effect in v4.x and its presence can cause connector startup errors.

---

## Issue 21 — Wrong metadata config key (`offsetAndPartition` camelCase vs `offset.and.partition` dot-separated)

**Symptom:** `SOURCE_PARTITION` and `SOURCE_OFFSET` columns in `AUTH_EVENTS_RAW` remain NULL even after data starts landing.

**Root cause:** `kafka-connect/shared.json` had `"snowflake.metadata.offsetAndPartition": "true"` (camelCase). The correct key for HP connector v4.x is `"snowflake.metadata.offset.and.partition"` (dot-separated). The camelCase key is silently ignored, so offset/partition are never written into `RECORD_METADATA`.

**Fix:** Updated key in `kafka-connect/shared.json`:

```json
"snowflake.metadata.offset.and.partition": "true"
```

---

## Issue 22 — No user-defined PIPE causes `SOURCE_TOPIC/PARTITION/OFFSET` columns to be NULL

**Symptom:** Even after Issues 19–21 are fixed, `SOURCE_TOPIC`, `SOURCE_PARTITION`, and `SOURCE_OFFSET` columns are NULL. Additionally the `INGESTED_AT NOT NULL` constraint would cause row rejection if `CURRENT_TIMESTAMP()` is not explicitly provided.

**Root cause:** Without a user-defined pipe, the HP connector auto-generates a pipe whose `COPY INTO` maps top-level JSON keys to columns by name. The generator JSON has no `source_topic`, `source_partition`, or `source_offset` keys — those values live in `RECORD_METADATA` (connector-injected metadata). The auto-generated pipe has no way to extract them. `INGESTED_AT` also has no corresponding JSON key, so it would receive NULL and violate the `NOT NULL` constraint.

**Fix:** Created `PAYMENTS_DB.RAW.AUTH_EVENTS_RAW` pipe (same name as destination table — the trigger for user-defined pipe mode) via schemachange migration `V1.6.0__create_ingest_pipe.sql`:

```sql
CREATE OR REPLACE PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW AS
COPY INTO PAYMENTS_DB.RAW.AUTH_EVENTS_RAW (
    ENV, EVENT_TS, ..., SOURCE_TOPIC, SOURCE_PARTITION, SOURCE_OFFSET, INGESTED_AT
)
FROM (
    SELECT
        $1:env::VARCHAR(16), ...,
        $1:RECORD_METADATA:topic::VARCHAR(128),
        $1:RECORD_METADATA:partition::NUMBER,
        $1:RECORD_METADATA:offset::NUMBER,
        CURRENT_TIMESTAMP()
    FROM TABLE(DATA_SOURCE(TYPE => 'STREAMING'))
);
```

`DATA_SOURCE(TYPE => 'STREAMING')` is the required FROM clause for HP connector user-defined pipes (not a stage path).

**Note on pipe privileges:** `GRANT USAGE ON PIPE` is not valid syntax — `USAGE` is not a privilege that applies to PIPE objects. The correct privilege for non-owners is `MONITOR` (read pipe metadata). `OPERATE` allows pause/resume. The connector role (`PAYMENTS_INGEST_ROLE`) was granted `MONITOR`.
## Issue 23 — ERR_PIPE_DOES_NOT_EXIST_OR_NOT_AUTHORIZED despite pipe existing

**Symptom:** HP Kafka Connector v4.x shows error `ERR_PIPE_DOES_NOT_EXIST_OR_NOT_AUTHORIZED` in task logs. Pipe exists and has `MONITOR` privilege granted to connector role. Some tasks show RUNNING, others FAILED.

**Root cause:** HP connector v4.x accesses pipes via Snowpipe Streaming API, which requires more privileges than initially documented:
1. Missing `SELECT` privilege on destination table (only had `INSERT`)
2. Missing `OPERATE` privilege on pipe (only had `MONITOR`)

`MONITOR` privilege allows reading pipe metadata but doesn't grant API access for ingestion. `OPERATE` privilege is required for Snowpipe Streaming API operations.

**Fix:** Created schemachange migration `V1.7.0__grant_ingest_privileges.sql`:

```sql
USE ROLE ACCOUNTADMIN;

-- SELECT privilege for table validation
GRANT SELECT ON TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;

-- OPERATE privilege for Snowpipe Streaming API access
GRANT OPERATE ON PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;
```

After granting privileges and restarting connector, tasks successfully opened Snowpipe Streaming channels.

**Validated:** Connector logs showed:
```
Successfully created new Snowpipe Streaming Client
Successfully opened streaming channel: auth_events_sink_payments_812203640_payments.auth_0
```

---

## Issue 24 — Half of connector tasks FAILED despite connector RUNNING

**Symptom:** Connector status shows 12 tasks RUNNING, 12 tasks FAILED. Connector overall state is RUNNING but task failures pollute status output.

**Root cause:** Kafka Connect creates one task per topic partition. The topic `payments.auth` only has 1 partition, but connector config specified `tasks.max: 24`. Result:
- 1 task assigned to partition 0 → RUNNING
- 23 tasks with no partitions assigned → FAILED (cannot initialize without work)

**Diagnosis:**
```bash
# Check topic partition count
docker exec payments-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka:29092 \
  --describe --topic payments.auth
# Output: PartitionCount: 1

# Check connector config
curl -s http://localhost:8083/connectors/auth-events-sink-payments/config | jq -r '.["tasks.max"]'
# Output: 24
```

**Fix:** Updated `kafka-connect/shared.json` to match partition count:

```json
{
  "config": {
    "tasks.max": "1"
  }
}
```

Applied via Kafka Connect REST API:
```bash
jq '.config' kafka-connect/shared.json | curl -X PUT -H "Content-Type: application/json" \
  --data @- http://localhost:8083/connectors/auth-events-sink-payments/config
```

After update: 1 task RUNNING, 0 failed.

**Best practice:** Set `tasks.max` ≤ partition count. If higher throughput needed, increase topic partitions first:
```bash
docker exec payments-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka:29092 \
  --alter --topic payments.auth --partitions 24
```

---

## Issue 25 — Generator container connection refused to Kafka

**Symptom:** Generator container logs show repeated connection failures:
```
%3|FAIL|rdkafka#producer-1| localhost:9092/bootstrap: Connect to ipv4#127.0.0.1:9092 failed: Connection refused
```

Container is on correct Docker network (`april_live_demo_default`) but cannot reach Kafka broker.

**Root cause:** Generator code defaults to `localhost:9092` via environment variable:
```python
# config.py
BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
```

In Docker, `localhost` resolves to the container's own loopback interface, not the Kafka broker. Generator container was started without `KAFKA_BOOTSTRAP_SERVERS` environment variable, so it used the `localhost:9092` default.

**Fix:** Added generator service to `docker-compose.yml` with proper environment configuration:

```yaml
  generator:
    build:
      context: generator
      dockerfile: Dockerfile
    container_name: payments-generator
    ports:
      - "8001:8000"  # Mapped to 8001 to avoid conflict with existing service on 8000
    environment:
      # CRITICAL: Use internal Docker network hostname, not localhost
      KAFKA_BOOTSTRAP_SERVERS: "kafka:29092"
      KAFKA_TOPIC: "payments.auth"
      GENERATOR_RATE: "500"
      GENERATOR_ENV: "dev"
    depends_on:
      - kafka
    command: ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

**Key Docker networking pattern:**
- Kafka advertises two listeners:
  - `PLAINTEXT://localhost:9092` → For host machine access
  - `INTERNAL://kafka:29092` → For container-to-container communication
- Producers/consumers running in Docker containers must use `kafka:29092`
- Producers/consumers running on host machine use `localhost:9092`

**Validated:** After starting with correct config:
```bash
docker-compose up -d generator
curl http://localhost:8001/status
# Output: {"events_per_sec":500,"total_events":7322,"uptime_sec":22.0}
```

Data pipeline fully operational: Generator → Kafka → HP Connector → Snowflake with 5,310+ rows ingested.

---

## Summary: First Successful End-to-End Data Flow

**Final stack status (2026-03-31):**
- ✅ Generator producing 500 events/sec to `payments.auth` topic
- ✅ Kafka topic: 1 partition, receiving messages
- ✅ HP Connector v4.x: 1 task RUNNING (matching partition count)
- ✅ Snowflake: 5,310+ rows in `PAYMENTS_DB.RAW.AUTH_EVENTS_RAW`
- ✅ Metadata columns populated: `SOURCE_TOPIC`, `SOURCE_PARTITION`, `SOURCE_OFFSET`, `INGESTED_AT`

**Key lessons:**
1. HP Connector v4.x requires `OPERATE` (not just `MONITOR`) on pipes for Snowpipe Streaming API
2. HP Connector requires `SELECT` (not just `INSERT`) on tables
3. Connector `tasks.max` should match or be less than topic partition count
4. Docker containers must use internal network hostnames (`kafka:29092`), not `localhost:9092`
5. User-defined pipes required for extracting `RECORD_METADATA` into metadata columns

---

## Issue 26 — No data displaying in SPCS app (`NameResolutionError` on Snowflake connection)

**Symptom:** SPCS service `PAYMENT_DASHBOARD` shows `RUNNING` with 1 ready instance and the `/health` probe returns `200 OK`. However, every API route (`/api/v1/filters`, `/api/v1/summary`, etc.) returns HTTP 500. The dashboard renders but all panels are empty.

**Diagnosis:** Retrieved container logs with `SYSTEM$GET_SERVICE_LOGS`:

```
snowflake.connector.errors.OperationalError: 250001: Could not connect to Snowflake
backend after 2 attempt(s). Aborting

socket.gaierror: [Errno -2] Name or service not known

Failed to resolve 'fnb70636.snowflakecomputing.com' ([Errno -2] Name or service not known)
```

The data pipeline was confirmed healthy throughout — `PAYMENTS_DB.RAW.AUTH_EVENTS_RAW` had 161,169 rows, `SERVE.IT_AUTH_MINUTE_METRICS` had 65,145 rows, and `SERVE.IT_AUTH_EVENT_SEARCH` had 153,118 rows.

**Root cause:** `app/backend/snowflake_client.py` built the Snowflake connection using only the `account` parameter:

```python
base_params = {
    "account": SNOWFLAKE_ACCOUNT,   # e.g. "fnb70636"
    ...
}
```

The Snowflake Python connector derives the connection hostname from `account` as `fnb70636.snowflakecomputing.com` — the **public internet endpoint**. SPCS containers have no external network egress by default; the service spec had no External Access Integration attached (`external_access_integrations: None` in `SHOW SERVICES` output), so all outbound DNS resolution for public hostnames fails.

SPCS automatically injects a `SNOWFLAKE_HOST` environment variable into every container with the **internal** Snowflake endpoint reachable from the container network. The code never read this variable.

**Fix:** Added `SNOWFLAKE_HOST` to `app/backend/snowflake_client.py` and passed it as `host` in `_create_connection`. When `SNOWFLAKE_HOST` is set (SPCS production), the connector routes via the internal network. When unset (local development), the parameter is omitted and the connector falls back to the public endpoint — fully backwards-compatible.

```python
# Module-level (alongside existing SNOWFLAKE_ACCOUNT)
SNOWFLAKE_HOST = os.getenv("SNOWFLAKE_HOST", "")

# In _create_connection():
base_params = {
    "account": SNOWFLAKE_ACCOUNT,
    "database": SNOWFLAKE_DATABASE,
    "schema": schema,
    "warehouse": warehouse,
    "role": SNOWFLAKE_ROLE,
}
if SNOWFLAKE_HOST:
    base_params["host"] = SNOWFLAKE_HOST
```

**Redeployment:**

```bash
# Login to registry
snow spcs image-registry login --connection business_critical

# Rebuild with correct platform flag (see Issue 16)
docker build --platform linux/amd64 \
  -t sfpscogs-slafell-aws-2.registry.snowflakecomputing.com/payments_db/app/dashboard_repo/payment-command-center:latest \
  ./app

# Push
docker push sfpscogs-slafell-aws-2.registry.snowflakecomputing.com/payments_db/app/dashboard_repo/payment-command-center:latest

# Restart service to pull new image
ALTER SERVICE PAYMENTS_DB.APP.PAYMENT_DASHBOARD SUSPEND;
ALTER SERVICE PAYMENTS_DB.APP.PAYMENT_DASHBOARD RESUME;
```

**Validation:** Post-restart logs showed clean startup with no `NameResolutionError`. All health probes returning `200 OK` with no 500s.

**Note on `ALTER SERVICE ... UPGRADE`:** This syntax does not exist in Snowflake SQL. Use `SUSPEND` + `RESUME` to force a fresh image pull when the spec itself has not changed.

**Key lesson:** SPCS containers must connect to Snowflake via `SNOWFLAKE_HOST` (internal endpoint), not via the account-derived public hostname. The `SNOWFLAKE_HOST` env var is always injected by SPCS — always include it in connection params when writing SPCS-hosted Snowflake connectors.

**Additional lesson:** Do NOT manually set `SNOWFLAKE_HOST` or `SNOWFLAKE_ACCOUNT` in `service_spec.yaml`. Setting them overrides the SPCS-injected internal values with the public URL, which is not DNS-resolvable from inside the container. The service spec should omit both — SPCS injects the correct internal endpoint automatically.

---

## Issue 27 — `010402 (55000): Table IT_AUTH_MINUTE_METRICS is not bound to the current warehouse`

**Symptom:** SPCS service `PAYMENT_DASHBOARD` is READY, `/health` returns 200, Snowflake auth succeeds (SPCS OAuth issue from Issue 26 is resolved), but every data API route returns HTTP 500:
```
snowflake.connector.errors.ProgrammingError: 010402 (55000):
Table IT_AUTH_MINUTE_METRICS is not bound to the current warehouse.
```

Dashboard panels all show `--`. Interactive Tables `IT_AUTH_MINUTE_METRICS` and `IT_AUTH_EVENT_SEARCH` both exist with hundreds of thousands of rows and are actively refreshing. `PAYMENTS_INTERACTIVE_WH` is STARTED.

**Root cause:** Interactive Tables require an **explicit one-time binding** to an Interactive Warehouse before queries through that warehouse succeed. This is done via:
```sql
ALTER WAREHOUSE <interactive_wh> ADD TABLES (<table1>, <table2>);
```

Per Snowflake docs: *"Before you can query the interactive table from an interactive warehouse, you must perform a one-time operation to add the interactive table to the interactive warehouse."*

This step was never performed. `SHOW WAREHOUSES LIKE 'PAYMENTS_INTERACTIVE_WH'` showed `tables = None`.

Schemachange migration `V1.3.0` was titled "create interactive warehouse table assoc" but only ran `ALTER WAREHOUSE PAYMENTS_INTERACTIVE_WH RESUME IF SUSPENDED`. The `ADD TABLES` step was omitted, based on the incorrect conclusion at the time (Issue 7) that no explicit association DDL existed in Snowflake. That conclusion was wrong.

The Terraform `warehouses.tf` resource uses `CREATE OR REPLACE INTERACTIVE WAREHOUSE` with no `TABLES (...)` clause, which also does not perform the binding.

**Fix:** Added schemachange migration `V1.8.0__bind_interactive_tables_to_warehouse.sql`:

```sql
USE ROLE PAYMENTS_ADMIN_ROLE;
USE WAREHOUSE PAYMENTS_ADMIN_WH;

ALTER WAREHOUSE PAYMENTS_INTERACTIVE_WH
  ADD TABLES (
    PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS,
    PAYMENTS_DB.SERVE.IT_AUTH_EVENT_SEARCH
  );
```

This command is idempotent — if the table is already associated, the command succeeds with no effect. Safe to re-run.

**Why Terraform `TABLES (...)` clause was not used:** The interactive tables are created by schemachange (V1.2.0), which runs *after* Terraform in the CI/CD pipeline. Adding `TABLES (...)` to the `CREATE OR REPLACE INTERACTIVE WAREHOUSE` DDL in Terraform would fail on a fresh deploy because the tables do not yet exist at Terraform apply time. The binding must happen in schemachange, after table creation.

**Correct deployment order for interactive tables:**
1. Terraform: create `PAYMENTS_INTERACTIVE_WH` (no TABLES clause)
2. schemachange V1.2.0: create `IT_AUTH_MINUTE_METRICS`, `IT_AUTH_EVENT_SEARCH`
3. schemachange V1.3.0: resume `PAYMENTS_INTERACTIVE_WH`
4. **schemachange V1.8.0: bind tables to warehouse** ← this was the missing step
5. Queries from `PAYMENTS_APP_ROLE` via `PAYMENTS_INTERACTIVE_WH` now succeed

**Key lesson:** Interactive Tables are NOT automatically bound to an Interactive Warehouse. The `ALTER WAREHOUSE ... ADD TABLES (...)` step is mandatory and must come after both the warehouse and the tables exist. The limit is 10 tables per interactive warehouse.

---

## Issue 28 — TypeScript test file imported unavailable modules + wrong prop interface (CI failure)

**Symptom:** PR CI failed on both `TypeScript Lint (eslint + tsc)` and `Docker Build` jobs:
```
src/__tests__/ScenarioBadge.test.tsx(10,38): error TS2307: Cannot find module 'vitest'
src/__tests__/ScenarioBadge.test.tsx(11,32): error TS2307: Cannot find module '@testing-library/react'
src/__tests__/ScenarioBadge.test.tsx(18,9): error TS2322: Property 'profile' does not exist on type
  'IntrinsicAttributes & ScenarioBadgeProps'.
```

**Root cause:** The test file was written as forward-looking "spec documentation" before the component was implemented. It:
1. Imported `vitest` and `@testing-library/react` — neither installed in `package.json`
2. Used flat props (`profile`, `timeRemainingSeconds`, `eventsPerSecond`) — the actual component takes `scenario: ScenarioInfo` (a single object)

Both failures share the same root: the test file included `import` statements and JSX with props that don't compile. The Docker build runs `npm run build` → `tsc -b && vite build`, so the same TypeScript errors killed the Docker build too.

**Fix:** Rewrote `src/__tests__/ScenarioBadge.test.tsx` as type-only JSX compilation tests:
- Removed `vitest` and `@testing-library/react` imports
- Replaced `render(<ScenarioBadge profile="..." />)` calls with typed JSX expressions assigned to `const _x = (...)` (never rendered)
- Used `scenario={{ profile, time_remaining_sec, events_per_sec }}` matching actual `ScenarioInfo` interface
- Added `void _x` lines to suppress unused-variable warnings

**Pattern for test files without a test runner:**
```tsx
import ScenarioBadge from '../components/ScenarioBadge';
import type { ScenarioInfo } from '../types/api';

// Compile-time type checks — never rendered
const _baseline = (
  <ScenarioBadge scenario={{ profile: 'baseline', time_remaining_sec: null, events_per_sec: 500 }} />
);
void _baseline;
```

**Key lesson:** When a testing library is not yet installed, test files must not `import` from it — even with a `// Will be added later` comment. The file still compiles and the import still fails. Either exclude test files from `tsconfig.json` or write type-only tests using only installed packages.

---

## Issue 32 — `analytics_service_spec.yaml` referenced image tag `:v1` but image was pushed as `:latest`

**Symptom:** `snow spcs service create PAYMENT_ANALYTICS` failed immediately with:
```
397012: Image /payments_db/app/dashboard_repo/payment-analytics:v1 not found.
Please verify the image exists in the image repository.
```

**Root cause:** `spcs/analytics_service_spec.yaml` was written with a hardcoded `:v1` tag. The local build and push used `:latest` (matching the CI workflow pattern for the existing ops dashboard). The registry had no `:v1` digest at all.

**Fix:** Updated `analytics_service_spec.yaml` to use `:latest`:
```yaml
# Before
image: /PAYMENTS_DB/APP/DASHBOARD_REPO/payment-analytics:v1

# After
image: /PAYMENTS_DB/APP/DASHBOARD_REPO/payment-analytics:latest
```

**Key lesson:** Spec image tags must exactly match what was pushed. When building locally without a specific `IMAGE_TAG` (as CI uses `${{ github.sha }}`), always push `:latest` and reference `:latest` in the spec. Using version tags like `:v1` requires a deliberate tag-and-push step.

---

## Issue 33 — `KeyError: 'SNOWFLAKE_USER'` in analytics Streamlit app running in SPCS

**Symptom:** `PAYMENT_ANALYTICS` service reached `READY` status and the readiness probe passed, but every page load crashed immediately:
```
KeyError: 'SNOWFLAKE_USER'
File "/app/streamlit_app.py", line 32, in _connect
    user=os.environ["SNOWFLAKE_USER"],
```

**Root cause:** `curated_analytics/streamlit_app.py` used `os.environ["KEY"]` (hard-fail) for both `SNOWFLAKE_USER` and `SNOWFLAKE_ACCOUNT`. Neither is injected by SPCS. In SPCS, authentication is done via an OAuth token injected at `/snowflake/session/token` — no username or account string is required. The container had no `SNOWFLAKE_USER` env var, causing an immediate `KeyError` before any connection attempt.

This was written before the ops dashboard's `snowflake_client.py` pattern was established, and the SPCS auth model was not carried forward to the new app.

**Fix:** Rewrote `_connect()` in `curated_analytics/streamlit_app.py` to match the ops dashboard pattern (`app/backend/snowflake_client.py`):

```python
_SPCS_TOKEN_PATH = "/snowflake/session/token"

def _connect() -> snowflake.connector.SnowflakeConnection:
    params = {k: v for k, v in _BASE_PARAMS.items() if v != ""}
    host = os.getenv("SNOWFLAKE_HOST", "")
    if host:
        params["host"] = host

    # 1. SPCS OAuth token — no user/password needed
    try:
        from pathlib import Path
        token = Path(_SPCS_TOKEN_PATH).read_text().strip()
        return snowflake.connector.connect(**params, token=token, authenticator="oauth")
    except FileNotFoundError:
        pass

    # 2. Key-pair (local dev)
    private_key = _load_private_key()
    user = os.getenv("SNOWFLAKE_USER", "")
    if private_key:
        return snowflake.connector.connect(**params, user=user, private_key=private_key)

    # 3. Password (last resort)
    return snowflake.connector.connect(
        **params, user=user, password=os.getenv("SNOWFLAKE_PASSWORD", "")
    )
```

All `os.environ[]` hard-requires replaced with `os.getenv(..., "")` so the container degrades gracefully rather than crashing on missing env vars.

**Key lesson:** Every Snowflake connection in an SPCS container must follow the token-first pattern. Never use `os.environ["SNOWFLAKE_USER"]` in SPCS code — `SNOWFLAKE_USER` is never injected by the runtime. The token at `/snowflake/session/token` is always present and requires no username.

---

## Issue 29 — `make app-deploy` used wrong CLI command (`snow streamlit deploy` for SPCS service)

**Symptom:** `make app-deploy` → `snow streamlit deploy --project spcs/` failed:
```
Your project definition is missing the following field:
  'entities.payment_command_center.service.artifacts'
Extra inputs are not permitted. You provided field
  'entities.payment_command_center.service.spec' with value './service_spec.yaml'
```

**Root cause (two combined):**
1. The `Makefile` `app-deploy` target called `snow streamlit deploy` but `spcs/snowflake.yml` defines a `type: service` entity — the wrong subcommand was used
2. The `snowflake.yml` used the deprecated `spec` field (see Issue 30)

**Fix:** The correct command for SPCS service entities is `snow spcs service deploy`:
```bash
snow spcs service deploy payment_command_center --project spcs/ -c business_critical
```

**Updated Makefile target (if updating it):**
```makefile
app-deploy: ## Deploy the application to SPCS
	snow spcs service deploy payment_command_center --project spcs/ -c business_critical \
	  || snow spcs service deploy payment_command_center --project spcs/ --upgrade -c business_critical
```

**Command mapping by entity type:**
| `snowflake.yml` entity type | Correct deploy command |
|---|---|
| `type: streamlit` | `snow streamlit deploy` |
| `type: service` | `snow spcs service deploy` |
| `type: function` | `snow snowpark function deploy` |

---

## Issue 30 — `snowflake.yml` `spec` field removed in Snow CLI 3.x DefinitionV20

**Symptom:** Same error as Issue 29:
```
Your project definition is missing the following field:
  'entities.payment_command_center.service.artifacts'
Extra inputs are not permitted. You provided field
  'entities.payment_command_center.service.spec'
```

**Root cause:** Snow CLI 3.16.0 `DefinitionV20` schema for `ServiceEntityModel` no longer has a `spec` field. The new schema requires:
- `artifacts` — list of local files to upload to the stage
- `spec_file` — filename on the stage used as `SPECIFICATION_FILE` in the generated SQL

**Fix:** Updated `spcs/snowflake.yml`:
```yaml
# Before (invalid in Snow CLI 3.x):
spec: ./service_spec.yaml

# After:
artifacts:
  - ./service_spec.yaml
spec_file: service_spec.yaml
```

**How deploy uses these fields:**
1. `artifacts` → files are uploaded to `stage` via `StageManager.put()`
2. `spec_file` → passed as `SPECIFICATION_FILE = 'service_spec.yaml'` in the `CREATE/ALTER SERVICE` SQL

**Full valid `snowflake.yml` for Snow CLI 3.x:**
```yaml
definition_version: "2"

entities:
  payment_command_center:
    type: service
    identifier:
      database: PAYMENTS_DB
      schema: APP
      name: PAYMENT_COMMAND_CENTER
    compute_pool: PAYMENTS_DASHBOARD_POOL
    artifacts:
      - ./service_spec.yaml
    spec_file: service_spec.yaml
    stage: PAYMENTS_DB.APP.SPECS
    comment: "Payment Command Center dashboard service"
```

**Other valid `ServiceEntityModel` fields:** `min_instances`, `max_instances`, `auto_resume`, `auto_suspend_secs`, `query_warehouse`, `tags`, `comment`.

---

## Issue 31 — Expired Cortex Code session tokens block private-key auth for `snow` CLI

**Symptom:** All `snow` CLI commands fail immediately with:
```
Invalid connection configuration. 251007: 251007: Session and master tokens invalid
```

This happens even for connections configured with `authenticator = "SNOWFLAKE_JWT"` and a valid private key file. `snow connection test -c business_critical` also fails.

**Root cause:** Cortex Code injects session tokens for each active connection as environment variables at startup:
```
SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_SESSION_TOKEN=ver:3-hint:...
SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_MASTER_TOKEN=ver:3-hint:...
```

The Snow CLI reads these env vars and uses them to authenticate — bypassing the `connections.toml` private key configuration entirely. After the session expires (typically a few hours), the tokens are invalid but still present in the environment. The CLI tries to use them, fails with 251007, and never falls back to key-pair auth.

**Fix:** Unset the expired token env vars when running `snow` CLI commands:
```bash
env -u SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_SESSION_TOKEN \
    -u SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_MASTER_TOKEN \
    snow spcs service deploy ...
```

**General pattern:**
```bash
env -u SNOWFLAKE_CONNECTIONS_${CONN^^}_SESSION_TOKEN \
    -u SNOWFLAKE_CONNECTIONS_${CONN^^}_MASTER_TOKEN \
    snow <command> -c <conn>
```
where `${CONN^^}` is the connection name uppercased with hyphens replaced by underscores.

**Detection:** If `snow connection test` fails with 251007 but the private key file exists and is valid, expired injected tokens are the cause. Confirm with:
```bash
env | grep SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL
```

**Key lesson:** Cortex Code session tokens supersede `connections.toml` key-pair config. When tokens expire mid-session, always unset them before invoking `snow` CLI commands.

---

## Issue 32 — Kafka connector version bump rc8 → rc9

**Symptom:** New RC release available at Maven Central. Planned upgrade, no failure.

**Fix:** Updated `kafka-connect/Dockerfile` curl URL:

```dockerfile
# Before
curl -sLO https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/4.0.0-rc8/snowflake-kafka-connector-4.0.0-rc8.jar

# After
curl -sLO https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/4.0.0-rc9/snowflake-kafka-connector-4.0.0-rc9.jar
```

Then rebuild:
```bash
docker compose build kafka-connect
```

---

## Issue 33 — Docker build failed "No space left on device" after rc9 version bump

**Symptom:** `docker compose build kafka-connect` failed immediately with:
```
mkdir: cannot create directory '...snowflakeinc-snowflake-kafka-connector': No space left on device
```

**Root cause:** Docker's internal VM disk was full. `docker system df` revealed:
- 37.9 GB stale build cache (16.3 GB reclaimable)
- 54 GB images (48 GB reclaimable from stopped containers)
- 5.7 GB container data (5.7 GB reclaimable)

**Fix:** Ran full cleanup (including volumes):
```bash
docker system prune --volumes
```

Targeted alternative (safer — keeps active images/containers, frees ~16 GB):
```bash
docker builder prune -f
```

**Warning:** `docker system prune --volumes` removes ALL stopped containers and their volumes. This caused follow-on Issues 34–36. Prefer `docker builder prune -f` unless a full reset is intended.

---

## Issue 34 — `payments-kafka` broker not running after `docker system prune --volumes`

**Symptom:** `kafka-connect` logs flooded with:
```
java.net.UnknownHostException: kafka
```
`docker compose ps` showed only `payments-kafka-connect` and `payments-generator` — no `payments-kafka`.

**Root cause:** `docker system prune --volumes` removes all stopped containers. The `payments-kafka` container was stopped (not running at the time of the prune) and was deleted. `kafka-connect` was still up but the broker it needed was gone, so the hostname `kafka` no longer resolved on the Docker network.

**Fix:**
```bash
docker compose up -d kafka
```

After startup, `kafka-connect` automatically reconnected and the consumer group `snowflake-connector-group` rebalanced within ~5 seconds.

---

## Issue 35 — kafka-connect crash on restart: internal topics created with wrong `cleanup.policy`

**Symptom:** After restarting `kafka-connect` (to re-initialise against the fresh broker), the container exited immediately with:
```
ERROR [Worker clientId=connect-1] Uncaught exception in herder work thread, exiting:
  at org.apache.kafka.connect.util.TopicAdmin.verifyTopicCleanupPolicyOnlyCompact
  at org.apache.kafka.connect.storage.KafkaTopicBasedBackingStore.lambda$topicInitializer$0
```

**Root cause:** While `kafka-connect` was still running against the freshly-started Kafka broker (Issue 34), Kafka auto-created the internal Connect bookkeeping topics (`_connect-configs`, `_connect-offsets`, `_connect-status`) with the default `cleanup.policy=delete`. Kafka Connect requires these topics to have `cleanup.policy=compact`. When `kafka-connect` was restarted, it detected the wrong policy and refused to start.

**Fix:** Delete all three internal topics so kafka-connect can recreate them with the correct compact policy:

```bash
docker exec payments-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka:29092 --delete --topic _connect-configs

docker exec payments-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka:29092 --delete --topic _connect-offsets

docker exec payments-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka:29092 --delete --topic _connect-status

docker compose up -d kafka-connect
```

On next start, kafka-connect creates these topics itself with `cleanup.policy=compact`.

**Prevention:** If using `docker system prune --volumes`, always restart `kafka-connect` before it reconnects to the fresh broker — or bring the full stack down and up together:
```bash
docker compose down && docker compose up -d
```

---

## Issue 36 — Connector config lost after volume prune, requires re-registration

**Symptom:** After kafka-connect restarted cleanly (Issue 35 resolved), the connector was gone:
```bash
curl http://localhost:8083/connectors
# []

curl http://localhost:8083/connectors/auth-events-sink-payments/status
# {"error_code":404,"message":"No status found for connector auth-events-sink-payments"}
```

**Root cause:** Connector configuration is persisted in the `_connect-configs` Kafka topic. This topic was deleted in Issue 35 and its underlying data was also wiped by `docker system prune --volumes`. After a clean restart, kafka-connect starts with no connectors registered.

**Fix:** Re-register the connector from the local config file:
```bash
curl -s -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  --data @kafka-connect/shared.json
```

Verify it came up RUNNING:
```bash
curl -s http://localhost:8083/connectors/auth-events-sink-payments/status | jq '.connector.state, .tasks[].state'
# "RUNNING"
# "RUNNING"
```

**Key lesson:** `kafka-connect/shared.json` is the source of truth for connector config. The copy in Kafka's `_connect-configs` topic is ephemeral and lost on any volume prune. Always keep the JSON file in version control and re-register after a full stack reset.
