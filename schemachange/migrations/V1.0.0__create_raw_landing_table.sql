-- =============================================================================
-- V1.0.0: Create raw landing table for card authorization events
-- Spec Reference: Sections 3.4, 3.4.1
--
-- This is the shared raw landing table for all environments (dev, preprod, prod).
-- Environment separation is logical via the `env` column.
-- =============================================================================

CREATE TABLE IF NOT EXISTS PAYMENTS_DB.RAW.AUTH_EVENTS_RAW (
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
        DEFAULT CURRENT_TIMESTAMP()                 COMMENT 'Snowflake ingestion timestamp'
)
COMMENT = 'Shared raw landing table for card authorization events across all environments (SYNTHETIC DATA ONLY - NO REAL CARDHOLDER DATA)'
ENABLE_SCHEMA_EVOLUTION = FALSE
DATA_RETENTION_TIME_IN_DAYS = 14;
