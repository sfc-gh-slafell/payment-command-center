# -----------------------------------------------------------------------------
# Compute Pools — SPCS compute for Payment Authorization Command Center
# Spec reference: Section 3.9.1
#
# Note: Compute pools are NOT a native Terraform resource in
# snowflakedb/snowflake v2.14. We use snowflake_execute for DDL.
# -----------------------------------------------------------------------------

resource "snowflake_execute" "payments_dashboard_pool" {
  execute = <<-EOT
    CREATE COMPUTE POOL IF NOT EXISTS PAYMENTS_DASHBOARD_POOL
      MIN_NODES        = 1
      MAX_NODES        = 2
      INSTANCE_FAMILY  = CPU_X64_S
      AUTO_SUSPEND_SECS = 3600
      COMMENT          = 'SPCS compute pool for Streamlit dashboard container'
  EOT
  revert  = "DROP COMPUTE POOL IF EXISTS PAYMENTS_DASHBOARD_POOL"
  query   = "SHOW COMPUTE POOLS LIKE 'PAYMENTS_DASHBOARD_POOL'"
}

resource "snowflake_execute" "grant_pool_to_app_role" {
  execute = "GRANT USAGE ON COMPUTE POOL PAYMENTS_DASHBOARD_POOL TO ROLE PAYMENTS_APP_ROLE"
  revert  = "REVOKE USAGE ON COMPUTE POOL PAYMENTS_DASHBOARD_POOL FROM ROLE PAYMENTS_APP_ROLE"
  query   = "SHOW GRANTS ON COMPUTE POOL PAYMENTS_DASHBOARD_POOL"

  depends_on = [snowflake_execute.payments_dashboard_pool]
}
