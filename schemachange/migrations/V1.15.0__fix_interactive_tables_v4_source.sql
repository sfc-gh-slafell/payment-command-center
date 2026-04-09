-- =============================================================================
-- V1.15.0: Fix interactive tables to read from AUTH_EVENTS_RAW_V4
--
-- Problem: V1.2.0 created both ITs reading from AUTH_EVENTS_RAW, which the
-- HP Kafka Connector auto-recreated with only RECORD_METADATA (no named
-- columns). The connector writes to AUTH_EVENTS_RAW_V4 (set via
-- snowflake.topic2table.map). Both ITs were auto-refreshing against 0 rows.
--
-- Changes:
--   - Source: AUTH_EVENTS_RAW → AUTH_EVENTS_RAW_V4
--   - Removed QUALIFY ROW_NUMBER() dedup: schema-evolved columns (ENV) cannot
--     be used in PARTITION BY for window functions on HP connector tables,
--     causing the IT to collapse all data into 2 minute buckets instead of
--     ~120. V4 HP Snowpipe Streaming guarantees exactly-once delivery per
--     Kafka offset, so row-level dedup is unnecessary.
-- =============================================================================

CREATE OR REPLACE INTERACTIVE TABLE PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS (
    event_minute            TIMESTAMP_NTZ,
    env                     VARCHAR(16),
    merchant_id             VARCHAR(32),
    merchant_name           VARCHAR(256),
    region                  VARCHAR(8),
    country                 VARCHAR(4),
    card_brand              VARCHAR(16),
    issuer_bin              VARCHAR(8),
    payment_method          VARCHAR(16),
    event_count             INTEGER,
    decline_count           INTEGER,
    approval_count          INTEGER,
    error_count             INTEGER,
    latency_sum_ms          BIGINT,
    latency_count           INTEGER,
    latency_0_50ms          INTEGER,
    latency_50_100ms        INTEGER,
    latency_100_200ms       INTEGER,
    latency_200_500ms       INTEGER,
    latency_500_1000ms      INTEGER,
    latency_1000ms_plus     INTEGER,
    total_amount            NUMBER(18,2),
    avg_amount              NUMBER(12,2)
)
    CLUSTER BY (event_minute, env, merchant_id, region)
    TARGET_LAG = '60 seconds'
    WAREHOUSE = PAYMENTS_REFRESH_WH
AS
SELECT
    DATE_TRUNC('MINUTE', event_ts)          AS event_minute,
    env,
    merchant_id,
    merchant_name,
    region,
    country,
    card_brand,
    issuer_bin,
    payment_method,
    COUNT(*)                                AS event_count,
    COUNT_IF(auth_status = 'DECLINED')      AS decline_count,
    COUNT_IF(auth_status = 'APPROVED')      AS approval_count,
    COUNT_IF(auth_status IN ('ERROR', 'TIMEOUT')) AS error_count,
    SUM(auth_latency_ms)                    AS latency_sum_ms,
    COUNT(*)                                AS latency_count,
    COUNT_IF(auth_latency_ms < 50)          AS latency_0_50ms,
    COUNT_IF(auth_latency_ms >= 50  AND auth_latency_ms < 100)  AS latency_50_100ms,
    COUNT_IF(auth_latency_ms >= 100 AND auth_latency_ms < 200)  AS latency_100_200ms,
    COUNT_IF(auth_latency_ms >= 200 AND auth_latency_ms < 500)  AS latency_200_500ms,
    COUNT_IF(auth_latency_ms >= 500 AND auth_latency_ms < 1000) AS latency_500_1000ms,
    COUNT_IF(auth_latency_ms >= 1000)       AS latency_1000ms_plus,
    SUM(amount)                             AS total_amount,
    AVG(amount)                             AS avg_amount
FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V4
WHERE event_ts >= DATEADD('HOUR', -2, SYSDATE())
GROUP BY ALL;


CREATE OR REPLACE INTERACTIVE TABLE PAYMENTS_DB.SERVE.IT_AUTH_EVENT_SEARCH (
    event_ts            TIMESTAMP_NTZ,
    env                 VARCHAR(16),
    event_id            VARCHAR(64),
    payment_id          VARCHAR(64),
    merchant_id         VARCHAR(32),
    merchant_name       VARCHAR(256),
    region              VARCHAR(8),
    country             VARCHAR(4),
    card_brand          VARCHAR(16),
    issuer_bin          VARCHAR(8),
    payment_method      VARCHAR(16),
    amount              NUMBER(12,2),
    currency            VARCHAR(4),
    auth_status         VARCHAR(16),
    decline_code        VARCHAR(32),
    auth_latency_ms     INTEGER
)
    CLUSTER BY (event_ts, env, merchant_id, auth_status)
    TARGET_LAG = '60 seconds'
    WAREHOUSE = PAYMENTS_REFRESH_WH
AS
SELECT
    event_ts,
    env,
    event_id,
    payment_id,
    merchant_id,
    merchant_name,
    region,
    country,
    card_brand,
    issuer_bin,
    payment_method,
    amount,
    currency,
    auth_status,
    decline_code,
    auth_latency_ms
FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V4
WHERE event_ts >= DATEADD('MINUTE', -60, SYSDATE())
ORDER BY event_ts DESC;
