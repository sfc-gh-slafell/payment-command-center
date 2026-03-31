-- =============================================================================
-- V1.3.0: Associate interactive tables with interactive warehouse and resume
-- Spec Reference: Section 3.6
--
-- The interactive warehouse was created via Terraform (warehouses.tf).
-- This migration associates both serving tables and resumes the warehouse.
-- =============================================================================

-- Associate interactive tables with the interactive warehouse
ALTER INTERACTIVE WAREHOUSE PAYMENTS_INTERACTIVE_WH SET
    TABLES = (
        PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS,
        PAYMENTS_DB.SERVE.IT_AUTH_EVENT_SEARCH
    );

-- Resume the interactive warehouse (created suspended by Terraform)
ALTER INTERACTIVE WAREHOUSE PAYMENTS_INTERACTIVE_WH RESUME IF SUSPENDED;
