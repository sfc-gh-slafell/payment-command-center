-- =============================================================================
-- V1.2.0: Create interactive serving tables
-- Spec Reference: Sections 3.5.1, 3.5.2, 3.6
--
-- Two interactive tables in PAYMENTS_DB.SERVE:
--   IT_AUTH_MINUTE_METRICS — minute-level aggregated metrics (22 columns)
--   IT_AUTH_EVENT_SEARCH   — recent event-level search (16 columns)
--
-- Key constraints:
--   - Interactive tables REQUIRE explicit column definitions
--   - WAREHOUSE must be a standard warehouse (PAYMENTS_REFRESH_WH), not interactive
--   - Interactive tables support INSERT OVERWRITE only — no UPDATE/DELETE
--   - Interactive tables cannot be sources for streams or dynamic tables
-- =============================================================================

-- ============================================================
-- IT_AUTH_MINUTE_METRICS — Minute-level aggregated metrics
-- ============================================================

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
WITH deduped_events AS (
    SELECT *
    FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW
    WHERE event_ts >= DATEADD('HOUR', -2, CURRENT_TIMESTAMP())
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY env, event_id
        ORDER BY ingested_at DESC
    ) = 1
)
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

    -- Event counts by status
    COUNT(*)                                AS event_count,
    COUNT_IF(auth_status = 'DECLINED')      AS decline_count,
    COUNT_IF(auth_status = 'APPROVED')      AS approval_count,
    COUNT_IF(auth_status IN ('ERROR', 'TIMEOUT'))
                                            AS error_count,

    -- Latency: sum and count for correct weighted average computation
    SUM(auth_latency_ms)                    AS latency_sum_ms,
    COUNT(*)                                AS latency_count,

    -- Latency histogram buckets for distribution analysis
    COUNT_IF(auth_latency_ms < 50)          AS latency_0_50ms,
    COUNT_IF(auth_latency_ms >= 50 AND auth_latency_ms < 100)
                                            AS latency_50_100ms,
    COUNT_IF(auth_latency_ms >= 100 AND auth_latency_ms < 200)
                                            AS latency_100_200ms,
    COUNT_IF(auth_latency_ms >= 200 AND auth_latency_ms < 500)
                                            AS latency_200_500ms,
    COUNT_IF(auth_latency_ms >= 500 AND auth_latency_ms < 1000)
                                            AS latency_500_1000ms,
    COUNT_IF(auth_latency_ms >= 1000)       AS latency_1000ms_plus,

    -- Amount aggregates
    SUM(amount)                             AS total_amount,
    AVG(amount)                             AS avg_amount
FROM deduped_events
GROUP BY ALL;


-- ============================================================
-- IT_AUTH_EVENT_SEARCH — Recent event-level search (60-min window)
-- ============================================================

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
WITH deduped_events AS (
    SELECT *
    FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW
    WHERE event_ts >= DATEADD('MINUTE', -60, CURRENT_TIMESTAMP())
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY env, event_id
        ORDER BY ingested_at DESC
    ) = 1
)
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
FROM deduped_events
ORDER BY event_ts DESC;
