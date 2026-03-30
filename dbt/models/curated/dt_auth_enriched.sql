{{
  config(
    materialized='dynamic_table',
    target_lag='5 minutes',
    snowflake_warehouse='PAYMENTS_REFRESH_WH',
    on_configuration_change='apply'
  )
}}

SELECT
    event_id,
    event_ts,
    env,
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
    auth_latency_ms,
    ingested_at,

    -- Latency tier classification
    CASE
        WHEN auth_latency_ms < 100  THEN 'FAST'
        WHEN auth_latency_ms < 300  THEN 'NORMAL'
        WHEN auth_latency_ms < 1000 THEN 'SLOW'
        ELSE 'CRITICAL'
    END AS latency_tier,

    -- System-generated decline vs card-holder decline
    CASE
        WHEN decline_code IN ('ISSUER_UNAVAILABLE', 'SYSTEM_ERROR', 'TIMEOUT')
        THEN TRUE
        ELSE FALSE
    END AS is_system_decline,

    -- Transaction value tier
    CASE
        WHEN amount >= 1000  THEN 'HIGH'
        WHEN amount >= 100   THEN 'MEDIUM'
        ELSE 'STANDARD'
    END AS value_tier,

    -- Auth outcome boolean for easy aggregation
    CASE WHEN auth_status = 'APPROVED' THEN 1 ELSE 0 END AS is_approved,
    CASE WHEN auth_status = 'DECLINED' THEN 1 ELSE 0 END AS is_declined

FROM {{ source('raw', 'AUTH_EVENTS_RAW') }}
-- 7-day rolling window per spec Section 3.8.1
WHERE event_ts >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
