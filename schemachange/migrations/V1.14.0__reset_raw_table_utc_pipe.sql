-- Reset AUTH_EVENTS_RAW to clear broken Snowpipe Streaming channel state
--
-- Root cause (DEPLOY_TROUBLESHOOTING.md Issue 35 / channel cleanup loop):
--   CREATE OR REPLACE PIPE invalidates all streaming channels bound to the pipe
--   object. Even after reverting the pipe and restarting the connector, the
--   Snowflake streaming materialize-to-table path remains broken: offsets advance
--   (data accepted into channel buffers) but nothing writes to table micro-
--   partitions. The only recovery is to drop the table, which clears all
--   server-side channel and pipe associations.
--
-- Combined fix applied here:
--   1. Table is dropped (clears channel state) and recreated (same DDL).
--   2. Pipe is recreated with CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())
--      so INGESTED_AT is stored in UTC — matches EVENT_TS timezone and works
--      correctly from both PDT and UTC Snowflake sessions (e.g. SPCS).
--   3. All required privileges are re-granted (CREATE OR REPLACE resets them).
--
-- Data impact: all existing rows (~20M synthetic demo events) are lost.
-- This is acceptable; data is regenerated automatically by the event generator.

USE ROLE PAYMENTS_ADMIN_ROLE;

DROP TABLE IF EXISTS PAYMENTS_DB.RAW.AUTH_EVENTS_RAW;

CREATE TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW (
    env                 VARCHAR(16)      NOT NULL   COMMENT 'Environment: dev, preprod, prod',
    event_ts            TIMESTAMP_NTZ    NOT NULL   COMMENT 'Event timestamp from source system',
    event_id            VARCHAR(64)      NOT NULL   COMMENT 'Unique event identifier (UUID) - business deduplication key within env',
    payment_id          VARCHAR(64)      NOT NULL   COMMENT 'Payment transaction identifier (synthetic/tokenized only)',
    merchant_id         VARCHAR(32)      NOT NULL   COMMENT 'Merchant identifier',
    merchant_name       VARCHAR(256)                COMMENT 'Merchant display name',
    region              VARCHAR(8)       NOT NULL   COMMENT 'Geographic region code (NA, EU, APAC, LATAM)',
    country             VARCHAR(4)       NOT NULL   COMMENT 'ISO 3166-1 alpha-2 country code',
    card_brand          VARCHAR(16)      NOT NULL   COMMENT 'Card network (VISA, MASTERCARD, AMEX, DISCOVER)',
    issuer_bin          VARCHAR(8)       NOT NULL   COMMENT 'Issuer Bank Identification Number (first 6-8 digits, synthetic)',
    payment_method      VARCHAR(16)      NOT NULL   COMMENT 'Payment method (CREDIT, DEBIT, PREPAID)',
    amount              NUMBER(12,2)     NOT NULL   COMMENT 'Transaction amount',
    currency            VARCHAR(4)       NOT NULL   COMMENT 'ISO 4217 currency code',
    auth_status         VARCHAR(16)      NOT NULL   COMMENT 'Authorization result (APPROVED, DECLINED, ERROR, TIMEOUT)',
    decline_code        VARCHAR(32)                 COMMENT 'Decline reason code (null if approved)',
    auth_latency_ms     INTEGER          NOT NULL   COMMENT 'Authorization round-trip latency in milliseconds',
    source_topic        VARCHAR(128)                COMMENT 'Originating Kafka topic name (populated by HP connector with snowflake.metadata.topic=true)',
    source_partition    INTEGER                     COMMENT 'Originating Kafka partition number (populated by HP connector with snowflake.metadata.offsetAndPartition=true)',
    source_offset       BIGINT                      COMMENT 'Originating Kafka offset (populated by HP connector with snowflake.metadata.offsetAndPartition=true)',
    headers             VARIANT                     COMMENT 'Kafka headers as key-value pairs',
    payload             VARIANT                     COMMENT 'Full original JSON payload for replay/debugging (synthetic data only)',
    ingested_at         TIMESTAMP_NTZ    NOT NULL
        DEFAULT CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ
                                                   COMMENT 'Snowflake ingestion timestamp (UTC)'
)
COMMENT = 'Shared raw landing table for card authorization events across all environments (SYNTHETIC DATA ONLY - NO REAL CARDHOLDER DATA)'
ENABLE_SCHEMA_EVOLUTION = FALSE
DATA_RETENTION_TIME_IN_DAYS = 14;

-- Re-grant table privileges (lost on DROP TABLE)
USE ROLE ACCOUNTADMIN;
GRANT INSERT ON TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;
GRANT SELECT ON TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_APP_ROLE;
GRANT SELECT ON TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_OPS_ROLE;

-- Recreate pipe with UTC INGESTED_AT
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

-- Re-grant pipe privileges (lost on CREATE OR REPLACE PIPE)
-- MONITOR: read pipe metadata
GRANT MONITOR ON PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;
-- OPERATE: required for Snowpipe Streaming API access
GRANT OPERATE ON PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;
