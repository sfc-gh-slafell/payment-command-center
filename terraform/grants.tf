# -----------------------------------------------------------------------------
# Grants — database USAGE and schema USAGE per role
# Spec reference: Sections 3.9.6, 6.3
#
# Grant mapping:
#   PAYMENTS_ADMIN_ROLE   — ALL PRIVILEGES on database, USAGE on all schemas
#   PAYMENTS_APP_ROLE     — USAGE on database, USAGE on APP + SERVE + RAW
#   PAYMENTS_INGEST_ROLE  — USAGE on database, USAGE on RAW
#   PAYMENTS_OPS_ROLE     — USAGE on database, USAGE on SERVE
# -----------------------------------------------------------------------------

# =============================================================================
# Database-level grants
# =============================================================================

resource "snowflake_grant_privileges_to_account_role" "admin_db_all" {
  account_role_name = snowflake_account_role.payments_admin.name
  all_privileges    = true

  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.payments_db.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "app_db_usage" {
  account_role_name = snowflake_account_role.payments_app.name
  privileges        = ["USAGE"]

  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.payments_db.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "ingest_db_usage" {
  account_role_name = snowflake_account_role.payments_ingest.name
  privileges        = ["USAGE"]

  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.payments_db.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "ops_db_usage" {
  account_role_name = snowflake_account_role.payments_ops.name
  privileges        = ["USAGE"]

  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.payments_db.name
  }
}

# =============================================================================
# Schema-level USAGE grants — PAYMENTS_ADMIN_ROLE (all four schemas)
# =============================================================================

resource "snowflake_grant_privileges_to_account_role" "admin_schema_raw" {
  account_role_name = snowflake_account_role.payments_admin.name
  privileges        = ["USAGE", "CREATE TABLE", "CREATE DYNAMIC TABLE", "CREATE STAGE", "CREATE PIPE"]

  on_schema {
    schema_name = snowflake_schema.raw.fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "admin_schema_serve" {
  account_role_name = snowflake_account_role.payments_admin.name
  privileges        = ["USAGE", "CREATE TABLE", "CREATE DYNAMIC TABLE"]

  on_schema {
    schema_name = snowflake_schema.serve.fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "admin_schema_curated" {
  account_role_name = snowflake_account_role.payments_admin.name
  privileges        = ["USAGE", "CREATE TABLE", "CREATE DYNAMIC TABLE"]

  on_schema {
    schema_name = snowflake_schema.curated.fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "admin_schema_app" {
  account_role_name = snowflake_account_role.payments_admin.name
  privileges        = ["USAGE", "CREATE STAGE", "CREATE IMAGE REPOSITORY", "CREATE SERVICE"]

  on_schema {
    schema_name = snowflake_schema.app.fully_qualified_name
  }
}

# =============================================================================
# Schema-level USAGE grants — PAYMENTS_APP_ROLE (APP, SERVE, RAW)
# =============================================================================

resource "snowflake_grant_privileges_to_account_role" "app_schema_app" {
  account_role_name = snowflake_account_role.payments_app.name
  privileges        = ["USAGE"]

  on_schema {
    schema_name = snowflake_schema.app.fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "app_schema_serve" {
  account_role_name = snowflake_account_role.payments_app.name
  privileges        = ["USAGE"]

  on_schema {
    schema_name = snowflake_schema.serve.fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "app_schema_raw" {
  account_role_name = snowflake_account_role.payments_app.name
  privileges        = ["USAGE"]

  on_schema {
    schema_name = snowflake_schema.raw.fully_qualified_name
  }
}

# =============================================================================
# Schema-level USAGE grants — PAYMENTS_INGEST_ROLE (RAW only)
# =============================================================================

resource "snowflake_grant_privileges_to_account_role" "ingest_schema_raw" {
  account_role_name = snowflake_account_role.payments_ingest.name
  privileges        = ["USAGE"]

  on_schema {
    schema_name = snowflake_schema.raw.fully_qualified_name
  }
}

# =============================================================================
# Schema-level USAGE grants — PAYMENTS_OPS_ROLE (SERVE only)
# =============================================================================

resource "snowflake_grant_privileges_to_account_role" "ops_schema_serve" {
  account_role_name = snowflake_account_role.payments_ops.name
  privileges        = ["USAGE"]

  on_schema {
    schema_name = snowflake_schema.serve.fully_qualified_name
  }
}
