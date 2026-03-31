-- =============================================================================
-- V1.8.0: Bind interactive tables to the interactive warehouse
-- Spec Reference: https://docs.snowflake.com/en/user-guide/interactive
--
-- Interactive tables require an explicit one-time binding to an interactive
-- warehouse via ALTER WAREHOUSE ... ADD TABLES (...) before queries through
-- that warehouse will succeed. Without this step, queries fail with:
--   010402 (55000): Table <name> is not bound to the current warehouse.
--
-- V1.3.0 (titled "warehouse table assoc") only resumed the warehouse. The
-- ADD TABLES step was missing, based on the incorrect conclusion at the time
-- that no explicit association DDL existed.
--
-- This command is idempotent: if the table is already associated, the command
-- succeeds with no effect. Safe to re-run.
-- =============================================================================

USE ROLE PAYMENTS_ADMIN_ROLE;
USE WAREHOUSE PAYMENTS_ADMIN_WH;

ALTER WAREHOUSE PAYMENTS_INTERACTIVE_WH
  ADD TABLES (
    PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS,
    PAYMENTS_DB.SERVE.IT_AUTH_EVENT_SEARCH
  );
