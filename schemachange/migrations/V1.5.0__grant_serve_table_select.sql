-- =============================================================================
-- V1.5.0: Explicit SELECT grants on SERVE interactive tables to PAYMENTS_APP_ROLE
--
-- V1.4.0 ran `GRANT SELECT ON ALL TABLES IN SCHEMA PAYMENTS_DB.SERVE` but
-- interactive tables are catalogued as DYNAMIC_TABLE type — that statement
-- silently skips them. These explicit table-level grants are required for
-- the dashboard backend to query IT_AUTH_MINUTE_METRICS and IT_AUTH_EVENT_SEARCH.
-- =============================================================================

GRANT SELECT ON TABLE PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS
    TO ROLE PAYMENTS_APP_ROLE;

GRANT SELECT ON TABLE PAYMENTS_DB.SERVE.IT_AUTH_EVENT_SEARCH
    TO ROLE PAYMENTS_APP_ROLE;
