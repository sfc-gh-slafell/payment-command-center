# -----------------------------------------------------------------------------
# Terraform Import Blocks (requires Terraform 1.7+)
#
# Makes `terraform apply` idempotent even when the state file is absent.
# On a cold run (empty state / cache miss), Terraform imports the existing
# Snowflake objects rather than failing with "002002: Object already exists".
#
# When the resource is already present in state the import block is a no-op
# (Terraform 1.7+ behaviour). This is safe to leave in the config permanently.
#
# Root cause of run 23774594215 failures:
#   Native TF resources (snowflake_database, snowflake_account_role,
#   snowflake_warehouse, etc.) issue plain CREATE statements. When state is
#   empty and objects already exist, every CREATE fails with 002002.
#   snowflake_execute resources already use CREATE OR REPLACE / IF NOT EXISTS
#   and are unaffected.
# -----------------------------------------------------------------------------

# --- Database ----------------------------------------------------------------

import {
  to = snowflake_database.payments_db
  id = "PAYMENTS_DB"
}

# --- Account Roles -----------------------------------------------------------

import {
  to = snowflake_account_role.payments_admin
  id = "PAYMENTS_ADMIN_ROLE"
}

import {
  to = snowflake_account_role.payments_app
  id = "PAYMENTS_APP_ROLE"
}

import {
  to = snowflake_account_role.payments_ingest
  id = "PAYMENTS_INGEST_ROLE"
}

import {
  to = snowflake_account_role.payments_ops
  id = "PAYMENTS_OPS_ROLE"
}

# --- Warehouses --------------------------------------------------------------
# Note: PAYMENTS_INTERACTIVE_WH is managed via snowflake_execute (CREATE OR
# REPLACE INTERACTIVE WAREHOUSE) and does not need an import block.

import {
  to = snowflake_warehouse.payments_refresh_wh
  id = "PAYMENTS_REFRESH_WH"
}

import {
  to = snowflake_warehouse.payments_admin_wh
  id = "PAYMENTS_ADMIN_WH"
}

# --- Schemas -----------------------------------------------------------------
# Provider v2.x uses pipe-separated compound identifiers: "database|schema"

import {
  to = snowflake_schema.raw
  id = "PAYMENTS_DB|RAW"
}

import {
  to = snowflake_schema.serve
  id = "PAYMENTS_DB|SERVE"
}

import {
  to = snowflake_schema.curated
  id = "PAYMENTS_DB|CURATED"
}

import {
  to = snowflake_schema.app
  id = "PAYMENTS_DB|APP"
}

# --- Resource Monitor --------------------------------------------------------

import {
  to = snowflake_resource_monitor.payments_monitor
  id = "PAYMENTS_MONITOR"
}

# --- Internal Stage ----------------------------------------------------------
# Provider v2.x: "database|schema|stage"

import {
  to = snowflake_stage_internal.specs
  id = "PAYMENTS_DB|APP|SPECS"
}
