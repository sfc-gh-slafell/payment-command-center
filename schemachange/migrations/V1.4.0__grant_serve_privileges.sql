-- =============================================================================
-- V1.4.0: Grant SELECT on SERVE schema tables to PAYMENTS_APP_ROLE
-- Spec Reference: Section 3.9.6
--
-- The APP role needs SELECT access to interactive tables in the SERVE schema
-- for dashboard queries via the interactive warehouse.
-- =============================================================================

-- Grant SELECT on all current tables in SERVE schema
GRANT SELECT ON ALL TABLES IN SCHEMA PAYMENTS_DB.SERVE
    TO ROLE PAYMENTS_APP_ROLE;

-- Grant SELECT on future tables in SERVE schema
GRANT SELECT ON FUTURE TABLES IN SCHEMA PAYMENTS_DB.SERVE
    TO ROLE PAYMENTS_APP_ROLE;
