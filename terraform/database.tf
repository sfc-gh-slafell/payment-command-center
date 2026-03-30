# -----------------------------------------------------------------------------
# PAYMENTS_DB — Primary database for all environments
# Spec reference: Section 6.2 (Naming Conventions), Section 7.1
# -----------------------------------------------------------------------------

resource "snowflake_database" "payments_db" {
  name                        = "PAYMENTS_DB"
  comment                     = "Payment Authorization Command Center — shared database for all environments"
  data_retention_time_in_days = 14
}
