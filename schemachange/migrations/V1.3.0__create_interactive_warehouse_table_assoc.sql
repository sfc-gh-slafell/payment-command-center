-- =============================================================================
-- V1.3.0: Resume interactive warehouse
-- Spec Reference: Section 3.6
--
-- The interactive warehouse was created via Terraform (warehouses.tf) in the
-- INITIALLY_SUSPENDED state. Resume it so it can serve queries on interactive
-- tables. No explicit table-to-warehouse association DDL exists in Snowflake;
-- the interactive warehouse automatically serves interactive/dynamic tables.
-- =============================================================================

-- Resume the interactive warehouse (created suspended by Terraform)
ALTER WAREHOUSE PAYMENTS_INTERACTIVE_WH RESUME IF SUSPENDED;
