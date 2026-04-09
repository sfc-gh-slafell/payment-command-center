-- =============================================================================
-- V1.16.0: Re-bind interactive tables to interactive warehouse
--
-- V1.15.0 used CREATE OR REPLACE INTERACTIVE TABLE which destroyed the
-- warehouse binding established in V1.8.0. Without this binding, queries
-- through PAYMENTS_INTERACTIVE_WH fail with:
--   010402 (55000): Table <name> is not bound to the current warehouse.
--
-- This is the root cause of the dashboard showing no data — the FastAPI
-- backend queries SERVE tables via the interactive warehouse, but the
-- recreated tables are no longer bound to it.
--
-- This command is idempotent: safe to re-run.
-- =============================================================================

USE ROLE PAYMENTS_ADMIN_ROLE;
USE WAREHOUSE PAYMENTS_ADMIN_WH;

ALTER WAREHOUSE PAYMENTS_INTERACTIVE_WH
  ADD TABLES (
    PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS,
    PAYMENTS_DB.SERVE.IT_AUTH_EVENT_SEARCH
  );
