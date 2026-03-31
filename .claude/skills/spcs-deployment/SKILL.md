---
name: spcs-deployment
description: End-to-end SPCS service deployment for this project using Snow CLI 3.x. Use when deploying or redeploying the payment-command-center service, debugging deploy errors, or updating spcs/snowflake.yml. Covers snowflake.yml schema, correct CLI commands, auth token issues, and the full deploy + URL workflow.
---

# SPCS Deployment — Payment Command Center

Consolidated runbook for deploying the SPCS service. Encodes every failure mode
encountered (Issues 12–17, 29–31 in DEPLOY_TROUBLESHOOTING.md) so they never repeat.

---

## Quick Deploy

```bash
# Run from project root
env -u SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_SESSION_TOKEN \
    -u SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_MASTER_TOKEN \
    snow spcs service deploy payment_command_center --project spcs/ -c business_critical
```

If service already exists (re-deploy / update):
```bash
env -u SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_SESSION_TOKEN \
    -u SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_MASTER_TOKEN \
    snow spcs service deploy payment_command_center --project spcs/ --upgrade -c business_critical
```

After deploy, get the URL:
```bash
env -u SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_SESSION_TOKEN \
    -u SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_MASTER_TOKEN \
    snow spcs service list-endpoints PAYMENT_COMMAND_CENTER \
      --database PAYMENTS_DB --schema APP -c business_critical
```
Endpoint provisioning takes ~2 minutes. Re-run until `ingress_url` appears.

---

## snowflake.yml — Required Schema (Snow CLI 3.x)

**File:** `spcs/snowflake.yml`

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
      - ./service_spec.yaml       # local file to upload to stage
    spec_file: service_spec.yaml  # filename used as SPECIFICATION_FILE in SQL
    stage: PAYMENTS_DB.APP.SPECS
    comment: "Payment Command Center dashboard service"
```

### Critical: `spec` is DEAD in Snow CLI 3.x

Snow CLI 3.16.0 `DefinitionV20` removed the `spec` field entirely.

| Old (broken) | New (correct) |
|---|---|
| `spec: ./service_spec.yaml` | `artifacts: [./service_spec.yaml]` + `spec_file: service_spec.yaml` |

Error you see with old schema:
```
Your project definition is missing the following field:
  'entities.payment_command_center.service.artifacts'
Extra inputs are not permitted. You provided field
  'entities.payment_command_center.service.spec'
```

### How the fields map to SQL

```sql
-- What snow spcs service deploy generates:
CREATE SERVICE PAYMENTS_DB.APP.PAYMENT_COMMAND_CENTER
  IN COMPUTE POOL PAYMENTS_DASHBOARD_POOL
  FROM @PAYMENTS_DB.APP.SPECS          -- from: stage
  SPECIFICATION_FILE = 'service_spec.yaml'  -- from: spec_file
  AUTO_RESUME = True
  MIN_INSTANCES = 1;
```

---

## CLI Command Reference

### DO NOT use `snow streamlit deploy` for service entities

```
snow streamlit deploy  →  only for  type: streamlit
snow spcs service deploy  →  for  type: service   ← use this
```

### Deploy lifecycle

```bash
# Initial create (service does not exist)
snow spcs service deploy payment_command_center --project spcs/ -c business_critical

# Update spec / rolling restart (service exists)
snow spcs service deploy payment_command_center --project spcs/ --upgrade -c business_critical

# Check status
snow spcs service describe PAYMENT_COMMAND_CENTER --database PAYMENTS_DB --schema APP -c business_critical

# Get logs (debugging startup failures)
snow spcs service logs PAYMENT_COMMAND_CENTER --container dashboard --database PAYMENTS_DB --schema APP -c business_critical
```

---

## Auth: Handling Expired Cortex Code Session Tokens

### Symptom
```
Invalid connection configuration. 251007: Session and master tokens invalid
```
Happens even when `connections.toml` uses `authenticator = "SNOWFLAKE_JWT"` with a valid private key.

### Root Cause
Cortex Code injects session tokens into the environment at startup:
```
SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_SESSION_TOKEN=ver:3-hint:...
SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_MASTER_TOKEN=ver:3-hint:...
```
The Snow CLI uses these in preference to key-pair auth. After a few hours they expire — the CLI fails with 251007 and does NOT fall back to the private key.

### Fix (always use this wrapper in Cortex Code sessions)
```bash
env -u SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_SESSION_TOKEN \
    -u SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_MASTER_TOKEN \
    snow <command> -c business_critical
```

### Detect expired tokens
```bash
# Check if tokens are present in env
env | grep SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL

# Confirm key-pair works once tokens are removed
env -u SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_SESSION_TOKEN \
    -u SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_MASTER_TOKEN \
    snow sql -q "SELECT CURRENT_USER()" -c business_critical
```

---

## Common Failure → Fix Reference

| Error | Root Cause | Fix |
|---|---|---|
| `251007: Session and master tokens invalid` | Expired Cortex Code tokens in env | `env -u ...SESSION_TOKEN -u ...MASTER_TOKEN snow ...` |
| `missing field 'service.artifacts'` | Old `spec:` field in `snowflake.yml` | Replace with `artifacts:` + `spec_file:` |
| `service.spec` not permitted | Same as above | Same fix |
| `snow streamlit deploy` schema error on service entity | Wrong subcommand | Use `snow spcs service deploy` |
| `002003: Service does not exist or not authorized` with `--upgrade` | Service not created yet | Remove `--upgrade` for initial deploy |
| `003001: Insufficient privileges on schema 'APP'` | Missing `CREATE SERVICE` grant | `GRANT CREATE SERVICE ON SCHEMA PAYMENTS_DB.APP TO ROLE PAYMENTS_APP_ROLE` |
| `SPCS only supports image for amd64` | ARM image pushed from Mac | Rebuild with `--platform linux/amd64` |
| All API routes return 500 / DNS failure | `SNOWFLAKE_HOST` not used | Read `SNOWFLAKE_HOST` env var; pass as `host=` in connector (see Issue 26) |
| `395018: unknown option 'serviceRoles'` | Invalid spec key | Remove `serviceRoles` from `service_spec.yaml` |
| Service stuck PENDING, readiness probe failing | ARM architecture image | `docker build --platform linux/amd64 ...` and push again |
| Endpoint URL shows "provisioning in progress" | Normal — takes ~2 min | Wait and re-run `list-endpoints` |

---

## Required Grants (one-time setup)

```sql
-- Role must exist and be assignable
GRANT USAGE ON COMPUTE POOL PAYMENTS_DASHBOARD_POOL TO ROLE PAYMENTS_APP_ROLE;
GRANT CREATE SERVICE ON SCHEMA PAYMENTS_DB.APP TO ROLE PAYMENTS_APP_ROLE;
GRANT USAGE ON DATABASE PAYMENTS_DB TO ROLE PAYMENTS_APP_ROLE;
GRANT USAGE ON SCHEMA PAYMENTS_DB.APP TO ROLE PAYMENTS_APP_ROLE;
GRANT READ ON IMAGE REPOSITORY PAYMENTS_DB.APP.DASHBOARD_REPO TO ROLE PAYMENTS_APP_ROLE;
```

---

## Snowflake Connection from Inside SPCS Containers

**DO NOT set `SNOWFLAKE_HOST` or `SNOWFLAKE_ACCOUNT` in `service_spec.yaml`.**
SPCS auto-injects the correct internal endpoint. Overriding it with the public URL causes DNS failure.

```python
# app/backend/snowflake_client.py — correct pattern
SNOWFLAKE_HOST = os.getenv("SNOWFLAKE_HOST", "")  # injected by SPCS

base_params = {"account": SNOWFLAKE_ACCOUNT, ...}
if SNOWFLAKE_HOST:
    base_params["host"] = SNOWFLAKE_HOST  # uses internal endpoint in SPCS
```

OAuth token is always at `/snowflake/session/token` inside the container.

---

## Full Redeploy Workflow (image + service)

When you've pushed a new Docker image and need to restart the service:

```bash
# 1. Login to registry (unset tokens first)
env -u SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_SESSION_TOKEN \
    -u SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_MASTER_TOKEN \
    snow spcs image-registry login -c business_critical

# 2. Build and push (always linux/amd64)
REGISTRY="sfpscogs-slafell-aws-2.registry.snowflakecomputing.com"
docker build --platform linux/amd64 \
  -t ${REGISTRY}/payments_db/app/dashboard_repo/payment-command-center:latest \
  -f app/Dockerfile app/
docker push ${REGISTRY}/payments_db/app/dashboard_repo/payment-command-center:latest

# 3. Deploy / upgrade service
env -u SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_SESSION_TOKEN \
    -u SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_MASTER_TOKEN \
    snow spcs service deploy payment_command_center --project spcs/ --upgrade -c business_critical

# 4. Get URL (wait ~2 min for provisioning)
env -u SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_SESSION_TOKEN \
    -u SNOWFLAKE_CONNECTIONS_BUSINESS_CRITICAL_MASTER_TOKEN \
    snow spcs service list-endpoints PAYMENT_COMMAND_CENTER \
      --database PAYMENTS_DB --schema APP -c business_critical
```

Registry hostname rule: all lowercase, underscores → hyphens.
`SFPSCOGS-SLAFELL_AWS_2` → `sfpscogs-slafell-aws-2.registry.snowflakecomputing.com`
