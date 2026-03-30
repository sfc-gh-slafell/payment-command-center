# -----------------------------------------------------------------------------
# Outputs — exported values for downstream tooling (schemachange, dbt, CI/CD)
# -----------------------------------------------------------------------------

output "database_name" {
  description = "Name of the payments database"
  value       = snowflake_database.payments_db.name
}

output "schema_names" {
  description = "Map of schema logical names to Snowflake schema names"
  value = {
    raw     = snowflake_schema.raw.name
    serve   = snowflake_schema.serve.name
    curated = snowflake_schema.curated.name
    app     = snowflake_schema.app.name
  }
}

output "role_names" {
  description = "Map of role logical names to Snowflake role names"
  value = {
    admin  = snowflake_account_role.payments_admin.name
    app    = snowflake_account_role.payments_app.name
    ingest = snowflake_account_role.payments_ingest.name
    ops    = snowflake_account_role.payments_ops.name
  }
}

# -----------------------------------------------------------------------------
# Issue #2 outputs — warehouses, compute, stages
# -----------------------------------------------------------------------------

output "warehouse_names" {
  description = "Map of warehouse logical names to Snowflake warehouse names"
  value = {
    interactive = "PAYMENTS_INTERACTIVE_WH"
    refresh     = snowflake_warehouse.payments_refresh_wh.name
    admin       = snowflake_warehouse.payments_admin_wh.name
  }
}

output "compute_pool_name" {
  description = "Name of the SPCS compute pool for the dashboard"
  value       = "PAYMENTS_DASHBOARD_POOL"
}

output "stage_names" {
  description = "Map of stage/repo logical names to Snowflake names"
  value = {
    specs_stage    = snowflake_stage_internal.specs.fully_qualified_name
    image_repo     = "DASHBOARD_REPO"
  }
}

output "resource_monitor_name" {
  description = "Name of the payments resource monitor"
  value       = snowflake_resource_monitor.payments_monitor.name
}
