-- Fix INGESTED_AT timezone: use explicit UTC instead of session-local CURRENT_TIMESTAMP()
--
-- Root cause (Issue 34 follow-up / Issue 35 in DEPLOY_TROUBLESHOOTING.md):
--   CURRENT_TIMESTAMP() in the pipe's COPY INTO inherits the Snowpipe process
--   session timezone (PDT = UTC-7 for this account). EVENT_TS from the generator
--   payload is UTC. Both are stored as TIMESTAMP_NTZ (no timezone info), so
--   DATEDIFF sees a -7 hour difference.
--
--   The Streamlit app running in SPCS uses a UTC session, so the time-window
--   filter (INGESTED_AT >= DATEADD('MINUTE', -N, CURRENT_TIMESTAMP())) also
--   fails: CURRENT_TIMESTAMP() returns 16:54 UTC but INGESTED_AT stores 09:54
--   PDT, so no rows match.
--
-- Fix: replace CURRENT_TIMESTAMP() with CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())
--   cast to TIMESTAMP_NTZ. This is timezone-agnostic regardless of session config.
--   Historical rows with PDT timestamps will be incorrect, but new rows are correct.

USE ROLE PAYMENTS_ADMIN_ROLE;

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
        CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ
    FROM TABLE(DATA_SOURCE(TYPE => 'STREAMING'))
);

-- MONITOR: read pipe metadata
GRANT MONITOR ON PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;
-- OPERATE: required for Snowpipe Streaming API access (see Issue 23 in DEPLOY_TROUBLESHOOTING.md)
-- CREATE OR REPLACE PIPE resets all grants, so both must be re-granted here.
GRANT OPERATE ON PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;
