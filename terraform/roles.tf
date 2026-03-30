# -----------------------------------------------------------------------------
# Role hierarchy for Payment Authorization Command Center
# Spec reference: Section 6.3
#
#   ACCOUNTADMIN
#     └── SYSADMIN
#           └── PAYMENTS_ADMIN_ROLE     (Terraform, schemachange, dbt)
#                 ├── PAYMENTS_APP_ROLE   (SPCS service owner, SELECT on serving)
#                 ├── PAYMENTS_INGEST_ROLE (Snowpipe Streaming, WRITE to raw)
#                 └── PAYMENTS_OPS_ROLE   (Dashboard viewers, service role)
# -----------------------------------------------------------------------------

# --- Account Roles ---

resource "snowflake_account_role" "payments_admin" {
  name    = "PAYMENTS_ADMIN_ROLE"
  comment = "Admin role for Terraform, schemachange, and dbt operations"
}

resource "snowflake_account_role" "payments_app" {
  name    = "PAYMENTS_APP_ROLE"
  comment = "SPCS service owner role — SELECT on serving and raw tables"
}

resource "snowflake_account_role" "payments_ingest" {
  name    = "PAYMENTS_INGEST_ROLE"
  comment = "Snowpipe Streaming ingest — WRITE access to raw landing table"
}

resource "snowflake_account_role" "payments_ops" {
  name    = "PAYMENTS_OPS_ROLE"
  comment = "Operations/dashboard viewers — granted SPCS service role"
}

# --- Role Hierarchy Grants ---

# PAYMENTS_ADMIN_ROLE → SYSADMIN
resource "snowflake_grant_account_role" "admin_to_sysadmin" {
  role_name        = snowflake_account_role.payments_admin.name
  parent_role_name = "SYSADMIN"
}

# PAYMENTS_APP_ROLE → PAYMENTS_ADMIN_ROLE
resource "snowflake_grant_account_role" "app_to_admin" {
  role_name        = snowflake_account_role.payments_app.name
  parent_role_name = snowflake_account_role.payments_admin.name
}

# PAYMENTS_INGEST_ROLE → PAYMENTS_ADMIN_ROLE
resource "snowflake_grant_account_role" "ingest_to_admin" {
  role_name        = snowflake_account_role.payments_ingest.name
  parent_role_name = snowflake_account_role.payments_admin.name
}

# PAYMENTS_OPS_ROLE → PAYMENTS_ADMIN_ROLE
resource "snowflake_grant_account_role" "ops_to_admin" {
  role_name        = snowflake_account_role.payments_ops.name
  parent_role_name = snowflake_account_role.payments_admin.name
}
