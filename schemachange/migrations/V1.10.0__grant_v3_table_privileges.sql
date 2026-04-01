-- =============================================================================
-- V1.10.0: Grant privileges for V3 connector on AUTH_EVENTS_RAW_V3 (Issue #59)
--
-- V3 Snowpipe Streaming Classic requires only INSERT.
-- SELECT is NOT required (unlike V4 HP which needs both INSERT + SELECT).
-- =============================================================================

USE ROLE ACCOUNTADMIN;

GRANT INSERT ON TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V3 TO ROLE PAYMENTS_INGEST_ROLE;
