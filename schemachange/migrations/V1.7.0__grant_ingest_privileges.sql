-- Grant missing privileges for HP Kafka Connector v4.x
--
-- Issue discovered: HP connector needs:
--   1. SELECT on table (in addition to INSERT) for validation
--   2. OPERATE on pipe (not just MONITOR) for Snowpipe Streaming API access
--
-- Without these, connector fails with ERR_PIPE_DOES_NOT_EXIST_OR_NOT_AUTHORIZED

USE ROLE ACCOUNTADMIN;

-- SELECT privilege for table validation
GRANT SELECT ON TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;

-- OPERATE privilege for Snowpipe Streaming API access
GRANT OPERATE ON PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;
