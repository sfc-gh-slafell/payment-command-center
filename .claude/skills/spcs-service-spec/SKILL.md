---
name: spcs-service-spec
description: Writing valid Snowflake SPCS (Snowpark Container Services) service specification YAML files. Use this skill when creating or modifying spcs/service_spec.yaml, debugging SPCS service creation errors (especially "unknown option" or "invalid spec"), granting SPCS-related privileges, or deploying services via snow spcs service create.
---

# SPCS Service Specification

## Purpose

Encode the valid SPCS service spec schema and required grants to prevent service creation failures. The `serviceRoles` gotcha alone caused a production deployment failure.

## Critical Rules

### Valid Spec Structure

The SPCS service spec YAML has a strict schema. Only these top-level keys are valid:

```yaml
spec:
  containers:         # REQUIRED — list of container definitions
  endpoints:          # OPTIONAL — list of endpoint definitions
  volumes:            # OPTIONAL — list of volume mounts
  logExporters:       # OPTIONAL — log export configuration
  platformMonitor:    # OPTIONAL — monitoring configuration
```

**`serviceRoles` is NOT a valid spec option.** Adding it causes:
```
395018 (22023): Invalid spec: unknown option 'serviceRoles' for 'spec'.
```

### Container Specification

```yaml
spec:
  containers:
    - name: dashboard
      image: /PAYMENTS_DB/APP/DASHBOARD_REPO/payment-command-center:latest
      env:
        SNOWFLAKE_WAREHOUSE: PAYMENTS_INTERACTIVE_WH
        SNOWFLAKE_DATABASE: PAYMENTS_DB
      readinessProbe:
        port: 8080
        path: /health
      resources:
        requests:
          memory: 1Gi
          cpu: "1"
        limits:
          memory: 2Gi
          cpu: "2"
```

**Container fields:**

| Field | Required | Description |
|---|---|---|
| `name` | Yes | Container identifier (lowercase, alphanumeric + hyphens) |
| `image` | Yes | Full image path: `/<DB>/<SCHEMA>/<REPO>/<IMAGE>:<TAG>` |
| `env` | No | Environment variables (key: value pairs) |
| `readinessProbe` | No | Health check (`port` + `path`) |
| `resources` | No | CPU/memory `requests` and `limits` |
| `command` | No | Override container entrypoint |
| `args` | No | Override container arguments |
| `volumeMounts` | No | Mount points for volumes |

### Endpoint Specification

```yaml
  endpoints:
    - name: dashboard
      port: 8080
      public: true     # Exposes via Snowflake ingress URL
```

**Endpoint fields:**
- `name` — must match a container name
- `port` — container port to expose
- `public: true` — creates a public HTTPS endpoint via Snowflake ingress
- `protocol` — optional, defaults to HTTPS

### Required Grants for Service Deployment

The role used for `snow spcs service create` needs:

```sql
-- CREATE SERVICE privilege on the target schema
GRANT CREATE SERVICE ON SCHEMA PAYMENTS_DB.APP TO ROLE PAYMENTS_APP_ROLE;

-- USAGE on the compute pool
GRANT USAGE ON COMPUTE POOL PAYMENTS_DASHBOARD_POOL TO ROLE PAYMENTS_APP_ROLE;

-- USAGE on the database and schema
GRANT USAGE ON DATABASE PAYMENTS_DB TO ROLE PAYMENTS_APP_ROLE;
GRANT USAGE ON SCHEMA PAYMENTS_DB.APP TO ROLE PAYMENTS_APP_ROLE;

-- READ on the image repository
GRANT READ ON IMAGE REPOSITORY PAYMENTS_DB.APP.DASHBOARD_REPO TO ROLE PAYMENTS_APP_ROLE;
```

**Error pattern:** `003001 (42501): Insufficient privileges to operate on schema 'APP'` means the role lacks `CREATE SERVICE` on that schema.

### Deployment Command (Idempotent Pattern)

Use `upgrade` first (idempotent — updates spec and restarts pods), fallback to `create` if service doesn't exist:

```bash
# Idempotent deployment — works for both initial deploy and updates
snow spcs service upgrade PAYMENT_DASHBOARD \
  --spec-path spcs/service_spec.yaml \
  --database PAYMENTS_DB \
  --schema APP \
  || snow spcs service create PAYMENT_DASHBOARD \
      --spec-path spcs/service_spec.yaml \
      --compute-pool PAYMENTS_DASHBOARD_POOL \
      --database PAYMENTS_DB \
      --schema APP
```

**Rationale:** `snow spcs service create` fails if service already exists (not idempotent). Using `upgrade || create` pattern makes CI re-runnable.

### Snowflake Connection from SPCS Containers

SPCS **automatically injects** `SNOWFLAKE_HOST` and `SNOWFLAKE_ACCOUNT` as environment variables into every running container. These point to the **internal** Snowflake network endpoint reachable from within the container — no External Access Integration required for Snowflake API calls when using SPCS OAuth token auth.

**Never set `SNOWFLAKE_HOST` or `SNOWFLAKE_ACCOUNT` in the service spec.** Doing so overrides the injected internal endpoint with the public Snowflake URL (e.g., `sfpscogs-slafell-aws-2.snowflakecomputing.com`), which is not DNS-resolvable from inside an SPCS container. Every API call will fail with:
```
socket.gaierror: [Errno -2] Name or service not known
Failed to resolve 'sfpscogs-slafell-aws-2.snowflakecomputing.com'
```

**Correct application code pattern** — read both vars but never hardcode them:
```python
SNOWFLAKE_HOST = os.getenv("SNOWFLAKE_HOST", "")    # auto-injected by SPCS
SNOWFLAKE_ACCOUNT = os.getenv("SNOWFLAKE_ACCOUNT", "")  # auto-injected by SPCS

base_params = {"account": SNOWFLAKE_ACCOUNT, ...}
if SNOWFLAKE_HOST:
    base_params["host"] = SNOWFLAKE_HOST  # uses internal endpoint in SPCS

# SPCS token auth — token lives at /snowflake/session/token
token = Path("/snowflake/session/token").read_text().strip()
snowflake.connector.connect(**base_params, token=token, authenticator="oauth")
```

**Correct service spec** — omit both vars, let SPCS inject them:
```yaml
env:
  SNOWFLAKE_WAREHOUSE: PAYMENTS_INTERACTIVE_WH   # fine to set
  SNOWFLAKE_DATABASE: PAYMENTS_DB                # fine to set
  # SNOWFLAKE_HOST: ...    ← DO NOT SET
  # SNOWFLAKE_ACCOUNT: ... ← DO NOT SET
```

The SPCS OAuth token itself is always available at `/snowflake/session/token` inside the container regardless of spec configuration.

## Common Pitfalls

1. **"unknown option 'serviceRoles'"** — Remove `serviceRoles` from spec. It's not a valid SPCS option.
2. **"Insufficient privileges on schema 'APP'"** — Role needs `CREATE SERVICE` on the schema AND `USAGE` on the compute pool.
3. **Image not found** — Image path must use the internal format `/<DB>/<SCHEMA>/<REPO>/<IMAGE>:<TAG>` (leading slash, no registry hostname). Role must have `READ` on the image repository.
4. **Service won't start** — Check readiness probe path exists in the container. `/health` must return 200.
5. **Resource limits too low** — Minimum 512Mi memory for most Python apps. FastAPI + React needs at least 1Gi.
6. **Service create fails on re-deploy** — Use `snow spcs service upgrade` first, fallback to `create` if it doesn't exist. `create` is not idempotent.
7. **All API routes return 500 / DNS failure** — Do not set `SNOWFLAKE_HOST` or `SNOWFLAKE_ACCOUNT` in the spec. See "Snowflake Connection from SPCS Containers" above.

## Valid vs Invalid Spec Keys

| Key | Valid? | Notes |
|---|---|---|
| `containers` | Yes | Required |
| `endpoints` | Yes | Optional |
| `volumes` | Yes | Optional |
| `logExporters` | Yes | Optional |
| `platformMonitor` | Yes | Optional |
| `serviceRoles` | **NO** | Causes error 395018 |
| `networkPolicy` | **NO** | Not a spec-level option |
| `replicas` | **NO** | Set via `--min-instances`/`--max-instances` CLI flags |
