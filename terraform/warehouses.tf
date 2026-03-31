# -----------------------------------------------------------------------------
# Warehouses — compute resources for Payment Authorization Command Center
# Spec reference: Sections 3.6, 3.7
#
# Three warehouses:
#   PAYMENTS_INTERACTIVE_WH — interactive type for low-latency queries
#   PAYMENTS_REFRESH_WH     — standard type for dynamic table refreshes
#   PAYMENTS_ADMIN_WH       — standard type for admin/ops tasks
#
# Note: Interactive warehouses are NOT supported as a native Terraform resource
# in snowflakedb/snowflake v2.14. The warehouse_type field only accepts
# STANDARD or SNOWPARK-OPTIMIZED. We use snowflake_execute for the interactive
# warehouse DDL.
# -----------------------------------------------------------------------------

# =============================================================================
# PAYMENTS_INTERACTIVE_WH — Interactive warehouse (via snowflake_execute)
# =============================================================================

resource "snowflake_execute" "payments_interactive_wh" {
  # Note: The TABLES (...) clause is intentionally omitted here.
  # Interactive tables (IT_AUTH_MINUTE_METRICS, IT_AUTH_EVENT_SEARCH) are
  # created by schemachange (V1.2.0), which runs AFTER Terraform. Adding TABLES
  # here would cause Terraform to fail on a fresh deploy (tables don't exist yet).
  # The warehouse-table binding is handled in schemachange migration V1.8.0:
  #   ALTER WAREHOUSE PAYMENTS_INTERACTIVE_WH ADD TABLES (...)
  execute = "CREATE OR REPLACE INTERACTIVE WAREHOUSE PAYMENTS_INTERACTIVE_WH WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 86400 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE COMMENT = 'Interactive warehouse for low-latency payment queries'"
  revert  = "DROP WAREHOUSE IF EXISTS PAYMENTS_INTERACTIVE_WH"
  query   = "SHOW WAREHOUSES LIKE 'PAYMENTS_INTERACTIVE_WH'"
}

# =============================================================================
# PAYMENTS_REFRESH_WH — Standard warehouse for dynamic table refreshes
# =============================================================================

resource "snowflake_warehouse" "payments_refresh_wh" {
  name                = "PAYMENTS_REFRESH_WH"
  warehouse_type      = "STANDARD"
  warehouse_size      = "XSMALL"
  auto_suspend        = 120
  auto_resume         = true
  initially_suspended = true
  comment             = "Standard warehouse for dynamic table and materialized view refreshes"
}

# =============================================================================
# PAYMENTS_ADMIN_WH — Standard warehouse for admin/ops tasks
# =============================================================================

resource "snowflake_warehouse" "payments_admin_wh" {
  name                = "PAYMENTS_ADMIN_WH"
  warehouse_type      = "STANDARD"
  warehouse_size      = "XSMALL"
  auto_suspend        = 60
  auto_resume         = true
  initially_suspended = true
  comment             = "Standard warehouse for admin and operational tasks"
}
