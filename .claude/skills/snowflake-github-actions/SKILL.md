---
name: snowflake-github-actions
description: GitHub Actions CI/CD patterns for Snowflake deployments including Terraform, schemachange, dbt, Docker push, and SPCS. Use this skill when writing or debugging GitHub Actions workflows that interact with Snowflake, troubleshooting "Account must be specified" errors in CI, configuring Snowflake authentication in GitHub Actions, or setting up multi-step deployment pipelines.
---

# Snowflake GitHub Actions Patterns

## Purpose

Encode the cross-cutting CI/CD patterns that prevent environment variable, secret, and authentication failures when deploying Snowflake workloads from GitHub Actions.

## Critical Rules

### SNOWFLAKE_ACCOUNT Must Be Set Per-Job

`SNOWFLAKE_ACCOUNT` does NOT automatically propagate from workflow-level `env` to every job. It must be explicitly set in each job that connects to Snowflake.

```yaml
# WRONG — workflow-level env doesn't propagate to all tools
env:
  SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}

jobs:
  dbt:
    runs-on: ubuntu-latest
    steps:
      - run: dbt run  # FAILS: "Account must be specified"

# CORRECT — set in each job's env
jobs:
  dbt:
    runs-on: ubuntu-latest
    env:
      SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
    steps:
      - run: dbt run  # Works
```

**Affected tools:** dbt, schemachange, snow CLI, Snowflake Python connector — ALL need `SNOWFLAKE_ACCOUNT` explicitly.

### Secret Interpolation Guards

`${{ secrets.X }}` resolves to empty string if the secret doesn't exist. Always guard optional secrets:

```yaml
# WRONG — curl fails with "URL rejected: No host part"
- name: Deploy Kafka connector
  run: curl -f -X POST "${KAFKA_CONNECT_URL}/connectors" ...

# CORRECT — conditional execution
- name: Deploy Kafka connector
  if: ${{ secrets.KAFKA_CONNECT_URL != '' }}
  run: curl -f -X POST "${KAFKA_CONNECT_URL}/connectors" ...
```

### Snowflake Private Key Setup Pattern

Every job that authenticates to Snowflake with key-pair needs this setup:

```yaml
- name: Write Snowflake private key
  run: |
    echo "${{ secrets.SNOWFLAKE_PRIVATE_KEY }}" > /tmp/snowflake_key.p8
    chmod 0600 /tmp/snowflake_key.p8

- name: Write connections.toml
  run: |
    mkdir -p ~/.snowflake
    cat > ~/.snowflake/connections.toml << 'EOF'
    [default]
    account = "${{ secrets.SNOWFLAKE_ACCOUNT }}"
    user = "${{ secrets.SNOWFLAKE_USER }}"
    authenticator = "SNOWFLAKE_JWT"
    private_key_file = "/tmp/snowflake_key.p8"
    EOF
    chmod 0600 ~/.snowflake/connections.toml
```

**Key points:**
- Key file must be `chmod 0600` — Snowflake driver rejects world-readable keys
- `connections.toml` also requires `chmod 0600`
- Always set `authenticator = "SNOWFLAKE_JWT"` alongside the key path

### Job Dependency Chain

Deploy jobs must run in this order (each depends on the previous):

```
1. Terraform Apply     (ACCOUNTADMIN — creates infra)
   ↓
2. schemachange Deploy (PAYMENTS_ADMIN_ROLE — runs migrations)
   ↓
3. dbt Run + Test      (PAYMENTS_ADMIN_ROLE — builds models)
   ↓
4. Docker Build + Push (PAYMENTS_APP_ROLE — pushes images)
   ↓
5. SPCS Service Deploy (PAYMENTS_APP_ROLE — deploys service)
   ↓
6. Kafka Connector     (OPTIONAL — conditional on secret)
```

```yaml
jobs:
  terraform:
    ...
  schemachange:
    needs: terraform
    ...
  dbt:
    needs: schemachange
    ...
  docker:
    needs: terraform   # Only needs infra, not data
    ...
  spcs:
    needs: docker
    ...
  kafka:
    needs: [schemachange, spcs]
    if: ${{ secrets.KAFKA_CONNECT_URL != '' }}
    ...
```

### Per-Job Environment Variables

Each job needs its own complete set of env vars. Here's the matrix:

| Env Var | Terraform | schemachange | dbt | Docker | SPCS |
|---|---|---|---|---|---|
| `SNOWFLAKE_ACCOUNT` | via TF_VAR | Yes | Yes | via connections | via connections |
| `SNOWFLAKE_USER` | via TF_VAR | Yes | Yes | via connections | via connections |
| `SNOWFLAKE_PRIVATE_KEY_PATH` | via TF_VAR | Yes | Yes | via connections | via connections |
| `SNOWFLAKE_AUTHENTICATOR` | N/A | `snowflake_jwt` | N/A | N/A | N/A |
| `REGISTRY_HOST` | N/A | N/A | N/A | Yes | N/A |

## Common Pitfalls

1. **"Account must be specified"** — `SNOWFLAKE_ACCOUNT` not set in the failing job's `env` block. Must be explicit per-job.
2. **Empty secret = silent failure** — `${{ secrets.MISSING }}` is empty string, not an error. Always use `if:` guards.
3. **Key file permissions** — `chmod 0600` on both `.p8` key and `connections.toml`. Driver rejects 0644.
4. **Terraform state lost** — Use `actions/cache` to persist `terraform.tfstate` between runs.
5. **connections.toml not found** — Snow CLI looks in `~/.snowflake/connections.toml`. Must `mkdir -p ~/.snowflake` first.
6. **Job env vs step env** — Job-level `env:` applies to all steps. Step-level `env:` only applies to that step. Prefer job-level for Snowflake vars.

## CI Workflow Pattern (Lint Only)

```yaml
jobs:
  python-lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - run: pip install ruff
      - run: ruff check generator/ fallback_ingest/ app/backend/
```

No Snowflake credentials needed for CI lint/compile jobs.
