

SELECT
    DATE_TRUNC('HOUR', event_ts)  AS event_hour,
    env,
    merchant_id,
    merchant_name,
    region,
    country,
    card_brand,
    issuer_bin,
    payment_method,

    -- Counts (reaggregatable)
    COUNT(*)                                              AS event_count,
    SUM(CASE WHEN auth_status = 'APPROVED' THEN 1 ELSE 0 END) AS approval_count,
    SUM(CASE WHEN auth_status = 'DECLINED' THEN 1 ELSE 0 END) AS decline_count,
    SUM(CASE WHEN auth_status IN ('ERROR', 'TIMEOUT') THEN 1 ELSE 0 END) AS error_count,

    -- Latency: SUM/COUNT for correct reaggregation (NOT AVG)
    SUM(auth_latency_ms)                                  AS latency_sum_ms,
    COUNT(auth_latency_ms)                                AS latency_count,

    -- Amount aggregates
    SUM(amount)                                           AS total_amount,
    MIN(amount)                                           AS min_amount,
    MAX(amount)                                           AS max_amount,

    -- Approval rate as inline expression (not alias)
    SUM(CASE WHEN auth_status = 'APPROVED' THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(*), 0)
                                                          AS approval_rate

FROM PAYMENTS_DB.CURATED_CURATED.dt_auth_enriched
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9