{{
  config(
    materialized='dynamic_table',
    target_lag='1 hour',
    snowflake_warehouse='PAYMENTS_REFRESH_WH',
    on_configuration_change='apply'
  )
}}

SELECT
    DATE_TRUNC('DAY', event_ts)  AS event_date,
    env,
    region,
    card_brand,

    -- Counts (reaggregatable)
    COUNT(*)                                              AS event_count,
    SUM(CASE WHEN auth_status = 'APPROVED' THEN 1 ELSE 0 END) AS approval_count,
    SUM(CASE WHEN auth_status = 'DECLINED' THEN 1 ELSE 0 END) AS decline_count,
    SUM(CASE WHEN auth_status IN ('ERROR', 'TIMEOUT') THEN 1 ELSE 0 END) AS error_count,

    -- Latency: SUM/COUNT for correct reaggregation (NOT AVG)
    SUM(auth_latency_ms)                                  AS latency_sum_ms,
    COUNT(auth_latency_ms)                                AS latency_count,

    -- p95 latency via PERCENTILE_CONT
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY auth_latency_ms) AS p95_latency_ms,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY auth_latency_ms) AS p99_latency_ms,

    -- Amount aggregates
    SUM(amount)                                           AS total_amount,

    -- Cardinality metrics
    COUNT(DISTINCT merchant_id)                           AS unique_merchants,
    COUNT(DISTINCT issuer_bin)                            AS unique_issuers,

    -- Approval rate inline
    SUM(CASE WHEN auth_status = 'APPROVED' THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(*), 0)
                                                          AS approval_rate

FROM {{ ref('dt_auth_enriched') }}
GROUP BY 1, 2, 3, 4
