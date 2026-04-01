-- =============================================================================
-- V1.9.0: Create V3 raw landing table for connector benchmark (Issue #59)
--
-- V3 Snowpipe Streaming Classic auto-creates two VARIANT columns:
--   RECORD_CONTENT  — full Kafka message JSON payload
--   RECORD_METADATA — Kafka provenance: topic, partition, offset, CreateTime,
--                     SnowflakeConnectorPushTime, etc.
--
-- This differs from AUTH_EVENTS_RAW (V4 HP) which uses named typed columns.
-- Queries require semi-structured syntax:
--   SELECT record_content:event_id::VARCHAR FROM AUTH_EVENTS_RAW_V3
-- =============================================================================

CREATE TABLE IF NOT EXISTS PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V3 (
    RECORD_CONTENT  VARIANT   COMMENT 'Full Kafka message JSON payload (V3 Snowpipe Streaming Classic schema)',
    RECORD_METADATA VARIANT   COMMENT 'Kafka provenance: topic, partition, offset, CreateTime, SnowflakeConnectorPushTime'
)
COMMENT = 'V3 Snowpipe Streaming Classic landing table for connector benchmark — two-VARIANT schema (SYNTHETIC DATA ONLY)'
DATA_RETENTION_TIME_IN_DAYS = 14;
