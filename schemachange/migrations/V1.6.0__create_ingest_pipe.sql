-- HP Kafka connector: user-defined pipe for AUTH_EVENTS_RAW
--
-- The HP connector checks for a pipe whose name matches the destination table
-- (case-insensitive). If found, it operates in "user-defined pipe mode" and
-- uses this pipe's COPY INTO to land records instead of auto-generating one.
--
-- A user-defined pipe is required here because:
--   1. SOURCE_TOPIC / SOURCE_PARTITION / SOURCE_OFFSET columns must be
--      populated from $1:RECORD_METADATA, which the auto-generated default
--      pipe does not do.
--   2. INGESTED_AT is NOT NULL — the auto-generated pipe would pass NULL for
--      any column not present as a top-level JSON key, violating the constraint.
--      Explicit CURRENT_TIMESTAMP() satisfies it without relying on the default.
--
-- Generator JSON keys: env, event_ts, event_id, payment_id, merchant_id,
--   merchant_name, region, country, card_brand, issuer_bin, payment_method,
--   amount, currency, auth_status, decline_code, auth_latency_ms
-- HEADERS and PAYLOAD are nullable and absent from generator output — omitted
-- from the column list so they remain NULL.

USE ROLE PAYMENTS_ADMIN_ROLE;

GRANT CREATE PIPE ON SCHEMA PAYMENTS_DB.RAW TO ROLE PAYMENTS_ADMIN_ROLE;

CREATE OR REPLACE PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW AS
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
);

-- USAGE is not a valid pipe privilege; MONITOR allows the role to read pipe metadata
GRANT MONITOR ON PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;
