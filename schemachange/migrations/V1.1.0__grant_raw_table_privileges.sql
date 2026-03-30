-- =============================================================================
-- V1.1.0: Grant privileges on AUTH_EVENTS_RAW to application roles
-- Spec Reference: Sections 3.9.6
--
-- Grant mapping:
--   PAYMENTS_INGEST_ROLE  — INSERT (Snowpipe Streaming / HP connector writes)
--   PAYMENTS_APP_ROLE     — SELECT (dashboard reads)
--   PAYMENTS_OPS_ROLE     — SELECT (operational monitoring)
-- =============================================================================

-- Ingest role needs INSERT to write raw events
GRANT INSERT ON TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW
    TO ROLE PAYMENTS_INGEST_ROLE;

-- App role needs SELECT for dashboard queries
GRANT SELECT ON TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW
    TO ROLE PAYMENTS_APP_ROLE;

-- Ops role needs SELECT for operational monitoring
GRANT SELECT ON TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW
    TO ROLE PAYMENTS_OPS_ROLE;
