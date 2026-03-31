---
name: terraform-vs-schemachange
description: Deciding which Snowflake objects belong in Terraform vs schemachange migrations for the Payment Authorization Command Center. Use this skill before creating or modifying any Snowflake DDL to determine the correct tool. Covers the pipe/connector outage root cause, deployment ordering, and the CREATE OR REPLACE danger.
---

# Terraform vs schemachange — Object Ownership

## The Core Rule

| Question | Answer → Tool |
|---|---|
| Is it infrastructure that exists before data flows? | **Terraform** |
| Does recreating it break an actively running connection? | **Terraform** (use `IF NOT EXISTS`) |
| Does it define how data is structured or queried? | **schemachange** |
| Must it run AFTER a table or other schemachange object exists? | **schemachange** |
| Does `terraform plan` need to show the change before it happens? | **Terraform** |

**One-line summary:** Terraform owns the skeleton. schemachange owns the data layer.

---

## Object Ownership Reference

### Terraform

| Object | Resource | Notes |
|---|---|---|
| Databases | `snowflake_database` | |
| Schemas | `snowflake_schema` | |
| Standard warehouses | `snowflake_warehouse` | |
| Interactive warehouses | `snowflake_execute` | Not natively supported in v2.14 |
| Roles | `snowflake_account_role` | |
| Role grants | `snowflake_grant_account_role` | |
| Privilege grants | `snowflake_grant_privileges_to_account_role` | |
| Resource monitors | `snowflake_resource_monitor` | |
| Compute pools | `snowflake_execute` (`IF NOT EXISTS`) | No REPLACE syntax |
| Image repositories | `snowflake_execute` | |
| Internal stages | `snowflake_stage_internal` | |
| **Pipes** | `snowflake_execute` (`IF NOT EXISTS`) | See critical note below |

### schemachange

| Object | Notes |
|---|---|
| Raw landing tables | Schema evolves with source changes |
| Dynamic tables | Query logic evolves with business rules |
| Interactive tables | Data layer — depends on tables existing first |
| Interactive warehouse → table binding | `ALTER WAREHOUSE ... ADD TABLES (...)` must run AFTER both table and warehouse exist |
| Table-level grants (INGEST_ROLE, APP_ROLE) | Granted on objects schemachange creates |
| Data seeds / reference tables | Pure data migration |

---

## ⚠ The Pipe Rule — Why Pipes Must Be in Terraform

**What happened (Issue 27, March 2026):**

schemachange migration `V1.6.0__create_ingest_pipe.sql` ran `CREATE OR REPLACE PIPE`. This dropped and recreated the pipe object. The HP Kafka connector had an active Snowpipe Streaming channel bound to the old pipe. When the pipe was replaced, the channel became invalid and the connector task failed immediately with a non-retryable error:

```
ERR_PIPE_DOES_NOT_EXIST_OR_NOT_AUTHORIZED (HTTP 404)
```

Data ingestion stopped for 18+ minutes (1,525,215 rows backed up in Kafka before recovery).

**Why schemachange is the wrong tool for pipes:**

- schemachange runs ALL pending versions during `make schema-deploy` — changes are not previewed
- Any future migration touching the pipe would require another `CREATE OR REPLACE PIPE`, repeating the outage
- There is no `ALTER PIPE SET COPY AS ...` in Snowflake — you must drop and recreate to change the definition

**The fix:**

Pipe moved to `terraform/pipes.tf` using `CREATE PIPE IF NOT EXISTS`:

```hcl
resource "snowflake_execute" "auth_events_raw_pipe" {
  execute = "CREATE PIPE IF NOT EXISTS PAYMENTS_DB.RAW.AUTH_EVENTS_RAW AS COPY INTO ..."
  revert  = "DROP PIPE IF EXISTS PAYMENTS_DB.RAW.AUTH_EVENTS_RAW"
  query   = "SHOW PIPES LIKE 'AUTH_EVENTS_RAW' IN SCHEMA PAYMENTS_DB.RAW"
}
```

`CREATE PIPE IF NOT EXISTS` means repeated `terraform apply` runs are safe no-ops. The pipe is never accidentally recreated.

**If you need to change the pipe definition:**

1. Change `execute` to `CREATE OR REPLACE PIPE ...` temporarily
2. Run `terraform apply`
3. Run `make connector-restart` — the connector task WILL be FAILED, this is expected
4. Confirm `make connector-status` shows `RUNNING`
5. Revert `execute` back to `CREATE PIPE IF NOT EXISTS`

---

## Deployment Order

Terraform and schemachange must run in this order. They are NOT interchangeable:

```
1. terraform apply
   └── Creates: roles, databases, schemas, warehouses, compute pools,
                stages, image repos, pipes, grants

2. schemachange deploy
   └── Creates: tables, dynamic tables, interactive tables,
                warehouse→table bindings, table-level grants

3. CI: docker build → push → snow streamlit deploy (or ALTER SERVICE)
```

**Why order matters:**

- schemachange migrations that reference `PAYMENTS_REFRESH_WH` require the warehouse to exist → Terraform must run first
- `ALTER WAREHOUSE PAYMENTS_INTERACTIVE_WH ADD TABLES (...)` requires both the warehouse AND the interactive tables to exist → must be in schemachange, after `CREATE INTERACTIVE TABLE` migrations
- The pipe (`terraform/pipes.tf`) uses `CREATE PIPE IF NOT EXISTS`, so even if schemachange runs before Terraform on a cold deploy, the pipe creation is safe

---

## The `CREATE OR REPLACE` Danger in schemachange

`CREATE OR REPLACE` in a schemachange migration is risky for any object with active downstream connections:

| Object | Risk if `CREATE OR REPLACE` is used |
|---|---|
| Pipe | Kafka connector task fails immediately (non-retryable) |
| Dynamic / Interactive table | Loses all data, resets refresh state |
| Stage | Breaks any running Snowpipe loading from that stage |
| Stream | Offset reset — downstream consumers may reprocess or miss data |

**Rule:** If an object has something actively reading from or writing to it, use `ALTER` (not `CREATE OR REPLACE`) in schemachange migrations. If `ALTER` is not supported for the change needed, put it in Terraform where `terraform plan` shows the impact first.

---

## Interactive Table Constraints (Learned the Hard Way)

1. **Minimum `TARGET_LAG` is 60 seconds.** Interactive tables are built on Dynamic Tables. Values below `60 seconds` fail with `002755: Dynamic Tables do not support lag values under 60 second(s)`.

2. **Warehouse binding is mandatory.** `ALTER WAREHOUSE <interactive_wh> ADD TABLES (...)` must be run once after the tables are created. Without it, every query fails with `010402 (55000): Table is not bound to the current warehouse`. This is in schemachange (V1.8.0), not Terraform, because the tables must exist first.

3. **`CREATE OR REPLACE INTERACTIVE TABLE` resets the binding.** If you ever recreate an interactive table, the warehouse binding in V1.8.0 becomes invalid. You must re-run the `ADD TABLES` step. Consider writing a new schemachange migration rather than modifying V1.8.0 (which is already applied).

---

## Common Pitfalls

1. **Putting pipes in schemachange** — Any future modification requires `CREATE OR REPLACE PIPE`, which silently kills the Kafka connector. Always use Terraform for pipes.

2. **Running `make schema-deploy` without checking what's pending** — Unlike `terraform plan`, schemachange gives no preview. Run `SELECT * FROM PAYMENTS_DB.RAW.SCHEMACHANGE_HISTORY ORDER BY INSTALLED_ON DESC` to see what's applied before deploying.

3. **Writing `CREATE OR REPLACE <table>` in a new migration** — Use `ALTER TABLE` for column additions. `CREATE OR REPLACE` wipes all data.

4. **Putting table-level grants in Terraform** — Grants on objects schemachange creates should be in schemachange migrations (or the version immediately following). Putting them in Terraform creates a circular dependency: Terraform runs before the table exists.

5. **Forgetting `ADD TABLES` after recreating an interactive table** — Write a new schemachange migration with `ALTER WAREHOUSE PAYMENTS_INTERACTIVE_WH ADD TABLES (...)` whenever `IT_AUTH_MINUTE_METRICS` or `IT_AUTH_EVENT_SEARCH` is recreated.

6. **Using `CREATE OR REPLACE` for pipes in Terraform** — Use `CREATE PIPE IF NOT EXISTS` in the `execute` field. This makes `terraform apply` a safe no-op when the pipe already exists, preventing accidental connector outages.

---

## Quick Reference

```bash
# What's been applied in schemachange?
SELECT version, script, status, installed_on
FROM PAYMENTS_DB.RAW.SCHEMACHANGE_HISTORY
ORDER BY installed_on DESC LIMIT 20;

# Check interactive warehouse binding
SHOW WAREHOUSES LIKE 'PAYMENTS_INTERACTIVE_WH';
-- Look at the `tables` column — should list both IT tables

# Check connector health before/after schema-deploy
make connector-status

# If connector task is FAILED after a pipe-touching deploy:
make connector-restart
```
