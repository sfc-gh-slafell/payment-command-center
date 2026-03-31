---
name: terraform-snowflake-provider
description: Snowflake Terraform provider v2.x configuration, authentication, idempotent DDL, state management, and RBAC grant patterns. Use this skill when writing or modifying Terraform files that manage Snowflake infrastructure (roles, warehouses, databases, schemas, compute pools, grants, resource monitors), debugging Terraform apply failures against Snowflake, or setting up CI/CD pipelines that run terraform apply.
---

# Terraform Snowflake Provider

## Purpose

Encode hard-won knowledge from production failures when using the Snowflake Terraform provider v2.x. Prevents "object already exists" errors, authentication failures, and privilege misconfigurations.

## Critical Rules

### Authentication (Provider v2.x)

The Snowflake Terraform provider v2.x has specific auth requirements that differ from v1.x:

```hcl
provider "snowflake" {
  organization_name = var.snowflake_organization_name
  account_name      = var.snowflake_account_name
  user              = var.snowflake_user
  authenticator     = "SNOWFLAKE_JWT"        # REQUIRED for key-pair auth
  private_key       = var.snowflake_private_key  # REQUIRED in provider block
  role              = "ACCOUNTADMIN"
  preview_features_enabled = ["snowflake_stage_resource"]
}
```

**Key requirements:**
- `authenticator = "SNOWFLAKE_JWT"` is **mandatory** for key-pair authentication — omitting it causes silent auth failure
- `private_key` must be set **directly in the provider block** — env vars alone do NOT work in v2.x
- Use `organization_name` + `account_name` (not the legacy `account` field)
- Pass the private key content via `TF_VAR_snowflake_private_key` in CI

### Idempotent DDL Patterns

Snowflake objects persist independently of Terraform state. If state is lost or stale, `CREATE` will fail with "object already exists." Always use idempotent patterns:

```hcl
# Roles — use snowflake_account_role resource (handles state)
resource "snowflake_account_role" "payments_admin" {
  name = "PAYMENTS_ADMIN_ROLE"
}

# For objects managed via snowflake_execute — use CREATE OR REPLACE
resource "snowflake_execute" "create_warehouse" {
  execute = "CREATE OR REPLACE WAREHOUSE PAYMENTS_WH ..."
  revert  = "DROP WAREHOUSE IF EXISTS PAYMENTS_WH"
}

# Compute pools — use IF NOT EXISTS (no REPLACE support)
resource "snowflake_execute" "compute_pool" {
  execute = "CREATE COMPUTE POOL IF NOT EXISTS PAYMENTS_POOL ..."
  revert  = "ALTER COMPUTE POOL PAYMENTS_POOL STOP ALL"
}
```

**Pattern summary:**

| Object Type | Idempotent Pattern |
|---|---|
| Roles | Native `snowflake_account_role` resource |
| Warehouses | `CREATE OR REPLACE WAREHOUSE` |
| Databases | `CREATE DATABASE IF NOT EXISTS` |
| Schemas | `CREATE SCHEMA IF NOT EXISTS` |
| Compute pools | `CREATE COMPUTE POOL IF NOT EXISTS` |
| Grants | Native `snowflake_grant_*` resources |
| Image repos | `CREATE IMAGE REPOSITORY IF NOT EXISTS` |

### State Management in CI

```yaml
# GitHub Actions pattern — cache tfstate between runs
- name: Restore Terraform state
  uses: actions/cache@v4
  with:
    path: terraform/terraform.tfstate
    key: tfstate-${{ github.sha }}
    restore-keys: tfstate-

- name: Terraform Apply
  run: terraform apply -auto-approve

- name: Cache Terraform state
  uses: actions/cache@v4
  with:
    path: terraform/terraform.tfstate
    key: tfstate-${{ github.sha }}
```

**Never run `terraform apply` without restoring state first** — this causes every object to be re-created, triggering "already exists" errors.

### Grant Hierarchy

Follow this role hierarchy for Snowflake RBAC:

```
ACCOUNTADMIN (Terraform only — never for app workloads)
  └── PAYMENTS_ADMIN_ROLE (DDL, migrations, dbt)
        ├── PAYMENTS_APP_ROLE (SPCS services, interactive queries)
        ├── PAYMENTS_INGEST_ROLE (Kafka writes to RAW)
        └── PAYMENTS_OPS_ROLE (read-only dashboards)
```

**Required grants per role:**

| Role | Needs |
|---|---|
| ADMIN | ALL on database, ALL SCHEMAS, CREATE on schemas |
| APP | USAGE on database/schemas, CREATE SERVICE on APP schema, USAGE on compute pool, SELECT on SERVE tables |
| INGEST | USAGE on database + RAW schema, INSERT on landing tables |
| OPS | USAGE on database + SERVE schema, SELECT on SERVE tables |

## Common Pitfalls

1. **"Object already exists"** — Missing or stale tfstate. Restore state cache before apply.
2. **Auth failure with key-pair** — Missing `authenticator = "SNOWFLAKE_JWT"` or `private_key` not in provider block.
3. **Grant to non-existent role** — Ensure role resources are created before grant resources using `depends_on`.
4. **Compute pool CREATE fails** — No `CREATE OR REPLACE` for compute pools. Use `IF NOT EXISTS`.
5. **Provider v2 breaking changes** — v2.x uses `organization_name` + `account_name`, not legacy `account`.

## Quick Reference

```bash
# CI env vars needed for Terraform
TF_VAR_snowflake_organization_name=${{ secrets.SNOWFLAKE_ORG }}
TF_VAR_snowflake_account_name=${{ secrets.SNOWFLAKE_ACCOUNT_NAME }}
TF_VAR_snowflake_user=${{ secrets.SNOWFLAKE_USER }}
TF_VAR_snowflake_private_key=${{ secrets.SNOWFLAKE_PRIVATE_KEY }}
```
