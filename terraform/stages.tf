# -----------------------------------------------------------------------------
# Stages & Image Repository — SPCS artifacts for dashboard deployment
# Spec reference: Sections 3.9.2, 3.9.6
#
# Resources:
#   DASHBOARD_REPO — image repository in APP schema for container images
#   SPECS          — internal stage in APP schema for service spec YAML files
#
# Note: Image repositories are NOT a native Terraform resource in
# snowflakedb/snowflake v2.14. We use snowflake_execute for DDL.
# The internal stage uses the native snowflake_stage resource.
# -----------------------------------------------------------------------------

# =============================================================================
# Image Repository — PAYMENTS_DB.APP.DASHBOARD_REPO
# =============================================================================

resource "snowflake_execute" "dashboard_repo" {
  execute = "CREATE OR REPLACE IMAGE REPOSITORY \"${snowflake_database.payments_db.name}\".\"${snowflake_schema.app.name}\".\"DASHBOARD_REPO\" COMMENT = 'Container image repository for Streamlit dashboard'"
  revert  = "DROP IMAGE REPOSITORY IF EXISTS \"${snowflake_database.payments_db.name}\".\"${snowflake_schema.app.name}\".\"DASHBOARD_REPO\""
  query   = "SHOW IMAGE REPOSITORIES LIKE 'DASHBOARD_REPO' IN SCHEMA \"${snowflake_database.payments_db.name}\".\"${snowflake_schema.app.name}\""
}

resource "snowflake_execute" "grant_repo_read_to_app_role" {
  execute = "GRANT READ ON IMAGE REPOSITORY \"${snowflake_database.payments_db.name}\".\"${snowflake_schema.app.name}\".\"DASHBOARD_REPO\" TO ROLE PAYMENTS_APP_ROLE"
  revert  = "REVOKE READ ON IMAGE REPOSITORY \"${snowflake_database.payments_db.name}\".\"${snowflake_schema.app.name}\".\"DASHBOARD_REPO\" FROM ROLE PAYMENTS_APP_ROLE"
  query   = "SHOW GRANTS ON IMAGE REPOSITORY \"${snowflake_database.payments_db.name}\".\"${snowflake_schema.app.name}\".\"DASHBOARD_REPO\""

  depends_on = [snowflake_execute.dashboard_repo]
}

# =============================================================================
# Spec Stage — PAYMENTS_DB.APP.SPECS
# =============================================================================

resource "snowflake_stage_internal" "specs" {
  database = snowflake_database.payments_db.name
  schema   = snowflake_schema.app.name
  name     = "SPECS"
  comment  = "Internal stage for SPCS service specification YAML files"
}
