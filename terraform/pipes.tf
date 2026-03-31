# -----------------------------------------------------------------------------
# Pipes — Snowpipe Streaming sink for HP Kafka Connector v4.x
# Spec reference: Section 3.5 (Ingest Pipeline)
#
# The HP connector operates in "user-defined pipe mode" when it finds a pipe
# whose name matches the destination table (AUTH_EVENTS_RAW, case-insensitive).
# This pipe's COPY INTO controls column mapping and populates the three
# RECORD_METADATA columns (SOURCE_TOPIC, SOURCE_PARTITION, SOURCE_OFFSET)
# that the auto-generated default pipe cannot produce.
#
# Why this pipe lives in Terraform (not schemachange):
#   The pipe is stable infrastructure — like a warehouse or stage. It should
#   only change when its definition deliberately changes, not as a side-effect
#   of running pending schemachange migrations. Terraform's plan/apply cycle
#   makes changes visible before they happen; schemachange runs new versions
#   immediately, which caused the connector outage documented in Issue 27.
#
# ⚠  IMPORTANT — CREATE PIPE IF NOT EXISTS is intentional:
#   Using CREATE OR REPLACE PIPE drops and recreates the pipe object. This
#   invalidates the HP connector's active streaming channel, causing the
#   connector task to fail immediately with:
#     ERR_PIPE_DOES_NOT_EXIST_OR_NOT_AUTHORIZED (HTTP 404, non-retryable)
#
#   IF NOT EXISTS means this resource is a no-op on every apply where the
#   pipe definition has not changed — the pipe is never accidentally recreated.
#
#   If you need to change the pipe definition:
#     1. Update `execute` below to use CREATE OR REPLACE PIPE temporarily
#     2. Run: terraform apply
#     3. Run: make connector-restart   ← mandatory, connector task will be FAILED
#     4. Confirm connector is RUNNING: make connector-status
#     5. Revert `execute` back to CREATE PIPE IF NOT EXISTS
#
# Grants:
#   GRANT MONITOR ON PIPE  → PAYMENTS_INGEST_ROLE  (schemachange V1.6.0)
#   GRANT OPERATE ON PIPE  → PAYMENTS_INGEST_ROLE  (schemachange V1.7.0)
#   GRANT SELECT ON TABLE  → PAYMENTS_INGEST_ROLE  (schemachange V1.7.0)
# -----------------------------------------------------------------------------

resource "snowflake_execute" "auth_events_raw_pipe" {
  execute = <<-EOT
    CREATE PIPE IF NOT EXISTS PAYMENTS_DB.RAW.AUTH_EVENTS_RAW AS
    COPY INTO PAYMENTS_DB.RAW.AUTH_EVENTS_RAW (
        ENV, EVENT_TS, EVENT_ID, PAYMENT_ID, MERCHANT_ID, MERCHANT_NAME,
        REGION, COUNTRY, CARD_BRAND, ISSUER_BIN, PAYMENT_METHOD,
        AMOUNT, CURRENCY, AUTH_STATUS, DECLINE_CODE, AUTH_LATENCY_MS,
        SOURCE_TOPIC, SOURCE_PARTITION, SOURCE_OFFSET,
        INGESTED_AT
    )
    FROM (
        SELECT
            $1:env::VARCHAR(16),
            $1:event_ts::TIMESTAMP_NTZ,
            $1:event_id::VARCHAR(64),
            $1:payment_id::VARCHAR(64),
            $1:merchant_id::VARCHAR(32),
            $1:merchant_name::VARCHAR(256),
            $1:region::VARCHAR(8),
            $1:country::VARCHAR(4),
            $1:card_brand::VARCHAR(16),
            $1:issuer_bin::VARCHAR(8),
            $1:payment_method::VARCHAR(16),
            $1:amount::NUMBER(12,2),
            $1:currency::VARCHAR(4),
            $1:auth_status::VARCHAR(16),
            $1:decline_code::VARCHAR(32),
            $1:auth_latency_ms::NUMBER,
            $1:RECORD_METADATA:topic::VARCHAR(128),
            $1:RECORD_METADATA:partition::NUMBER,
            $1:RECORD_METADATA:offset::NUMBER,
            CURRENT_TIMESTAMP()
        FROM TABLE(DATA_SOURCE(TYPE => 'STREAMING'))
    )
  EOT

  revert = "DROP PIPE IF EXISTS PAYMENTS_DB.RAW.AUTH_EVENTS_RAW"
  query  = "SHOW PIPES LIKE 'AUTH_EVENTS_RAW' IN SCHEMA PAYMENTS_DB.RAW"

}
