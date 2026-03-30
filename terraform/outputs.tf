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
