---
name: schemachange-snowflake
description: Deploying versioned SQL migrations to Snowflake using schemachange v4.x. Use this skill when writing schemachange config files, creating versioned SQL migration scripts, debugging schemachange auth or privilege errors, or integrating schemachange into CI/CD pipelines.
---

# schemachange for Snowflake

## Purpose

Encode production-learned patterns for running schemachange v4.x against Snowflake, preventing authentication failures, privilege errors, and configuration mistakes.

## Critical Rules

### Authentication Configuration

schemachange v4.x requires ALL of these to connect:

```yaml
# schemachange-config.yml
config-version: 1
root-folder: migrations
snowflake-account: "ORG-ACCOUNT"          # org-account format (hyphenated)
snowflake-user: "SVC_USER"
snowflake-role: "PAYMENTS_ADMIN_ROLE"
snowflake-warehouse: "PAYMENTS_ADMIN_WH"
snowflake-database: "PAYMENTS_DB"
snowflake-schema: "RAW"
```

**Environment variables for JWT auth:**
```bash
SNOWFLAKE_ACCOUNT="ORG-ACCOUNT"           # MUST be set explicitly
SNOWFLAKE_AUTHENTICATOR="snowflake_jwt"   # REQUIRED for key-pair
SNOWFLAKE_PRIVATE_KEY_PATH="/tmp/snowflake_key.p8"
```

**Common auth failure:** `251001: Account must be specified` means `SNOWFLAKE_ACCOUNT` env var is empty or not set in the job context.

### File Permissions

```bash
# connections.toml MUST be 0600 — Snowflake driver rejects world-readable key files
chmod 0600 ~/.snowflake/connections.toml
chmod 0600 /tmp/snowflake_key.p8
```

### Migration Privileges

The role running schemachange must have privileges on EVERY schema the migrations touch:

```sql
-- If migrations CREATE objects in SERVE schema:
GRANT CREATE TABLE ON SCHEMA PAYMENTS_DB.SERVE TO ROLE PAYMENTS_ADMIN_ROLE;
GRANT CREATE DYNAMIC TABLE ON SCHEMA PAYMENTS_DB.SERVE TO ROLE PAYMENTS_ADMIN_ROLE;

-- For interactive tables specifically:
GRANT CREATE INTERACTIVE TABLE ON SCHEMA PAYMENTS_DB.SERVE TO ROLE PAYMENTS_ADMIN_ROLE;
```

**Error pattern:** `003001 (42501): Insufficient privileges to operate on schema 'SERVE'` means the schemachange role lacks CREATE on that schema. Fix in Terraform grants, not in the migration.

### Migration Naming Convention

```
migrations/
  V1.0.0__create_raw_landing_table.sql
  V1.1.0__grant_raw_table_privileges.sql
  V1.2.0__create_interactive_tables.sql
  V1.3.0__alter_interactive_warehouse.sql
  V1.4.0__grant_serve_schema_privileges.sql
```

- Prefix: `V` (versioned), `R` (repeatable), `A` (always)
- Version: semver with dots (parsed for ordering)
- Separator: double underscore `__`
- Description: snake_case
- Extension: `.sql`

### CI Integration

```yaml
# GitHub Actions step
- name: schemachange deploy
  working-directory: schemachange   # MUST point to config root
  env:
    SNOWFLAKE_ACCOUNT: ${{ secrets.SNOWFLAKE_ACCOUNT }}
    SNOWFLAKE_AUTHENTICATOR: snowflake_jwt
    SNOWFLAKE_PRIVATE_KEY_PATH: /tmp/snowflake_key.p8
  run: schemachange deploy
```

**`working-directory` is critical** — schemachange looks for `schemachange-config.yml` and the `migrations/` folder relative to CWD.

## Common Pitfalls

1. **"Account must be specified"** — `SNOWFLAKE_ACCOUNT` not set in job env. GitHub secrets don't auto-propagate between jobs.
2. **"Insufficient privileges on schema X"** — Migration DDL targets a schema the role can't CREATE in. Add grants in Terraform.
3. **Config file not found** — `working-directory` doesn't point to the directory containing `schemachange-config.yml`.
4. **connections.toml permission denied** — File must be `chmod 0600`. Snowflake driver enforces this.
5. **Migration re-execution** — schemachange tracks applied versions in `SCHEMACHANGE_HISTORY` table. Don't modify already-applied V scripts.

## Quick Reference

```bash
# Test connection locally
schemachange verify

# Dry run
schemachange deploy --dry-run

# Deploy with debug logging
schemachange deploy -L DEBUG

# Check change history
SELECT * FROM PAYMENTS_DB.RAW.SCHEMACHANGE_HISTORY ORDER BY INSTALLED_ON DESC;
```
