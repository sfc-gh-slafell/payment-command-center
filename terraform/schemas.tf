# -----------------------------------------------------------------------------
# Schemas within PAYMENTS_DB
# Spec reference: Section 6.2 (Naming Conventions)
#
#   RAW      — Shared raw landing table (Snowpipe Streaming target)
#   SERVE    — Interactive tables for live dashboard serving
#   CURATED  — dbt-managed dynamic tables for enrichment and BI
#   APP      — SPCS deployment artifacts (image repo, service spec stage)
# -----------------------------------------------------------------------------

resource "snowflake_schema" "raw" {
  database = snowflake_database.payments_db.name
  name     = "RAW"
  comment  = "Shared raw landing for Snowpipe Streaming ingest (all environments)"

  data_retention_time_in_days = 14
}

resource "snowflake_schema" "serve" {
  database = snowflake_database.payments_db.name
  name     = "SERVE"
  comment  = "Interactive tables for low-latency dashboard serving"
}

resource "snowflake_schema" "curated" {
  database = snowflake_database.payments_db.name
  name     = "CURATED"
  comment  = "dbt-managed dynamic tables for enrichment, hourly/daily rollups"
}

resource "snowflake_schema" "app" {
  database = snowflake_database.payments_db.name
  name     = "APP"
  comment  = "SPCS deployment: image repository, service spec stage, service"
}
