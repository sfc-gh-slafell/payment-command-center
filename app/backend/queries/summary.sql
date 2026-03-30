-- summary.sql: KPI summary from IT_AUTH_MINUTE_METRICS with freshness
-- Parameters: :time_range_minutes, :env, :merchant_id, :region, :card_brand

WITH current_window AS (
    SELECT
        SUM(event_count)                                       AS total_events,
        SUM(approval_count)                                    AS total_approved,
        SUM(decline_count)                                     AS total_declined,
        SUM(error_count)                                       AS total_errors,
        SUM(latency_sum_ms) / NULLIF(SUM(latency_count), 0)   AS avg_latency_ms,
        SUM(total_amount)                                      AS total_amount
    FROM PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS
    WHERE event_minute >= DATEADD('MINUTE', -%(time_range_minutes)s, CURRENT_TIMESTAMP())
      AND (%(env)s IS NULL OR env = %(env)s)
      AND (%(merchant_id)s IS NULL OR merchant_id = %(merchant_id)s)
      AND (%(region)s IS NULL OR region = %(region)s)
      AND (%(card_brand)s IS NULL OR card_brand = %(card_brand)s)
),
previous_window AS (
    SELECT
        SUM(event_count)                                       AS total_events,
        SUM(approval_count)                                    AS total_approved,
        SUM(decline_count)                                     AS total_declined,
        SUM(error_count)                                       AS total_errors,
        SUM(latency_sum_ms) / NULLIF(SUM(latency_count), 0)   AS avg_latency_ms,
        SUM(total_amount)                                      AS total_amount
    FROM PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS
    WHERE event_minute >= DATEADD('MINUTE', -(%(time_range_minutes)s * 2), CURRENT_TIMESTAMP())
      AND event_minute < DATEADD('MINUTE', -%(time_range_minutes)s, CURRENT_TIMESTAMP())
      AND (%(env)s IS NULL OR env = %(env)s)
      AND (%(merchant_id)s IS NULL OR merchant_id = %(merchant_id)s)
      AND (%(region)s IS NULL OR region = %(region)s)
      AND (%(card_brand)s IS NULL OR card_brand = %(card_brand)s)
),
freshness AS (
    SELECT MAX(event_minute) AS last_serve_ts
    FROM PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS
)
SELECT
    c.total_events                                                    AS current_events,
    c.total_approved * 100.0 / NULLIF(c.total_events, 0)             AS current_approval_rate,
    c.total_declined * 100.0 / NULLIF(c.total_events, 0)             AS current_decline_rate,
    c.avg_latency_ms                                                  AS current_avg_latency_ms,
    p.total_events                                                    AS prev_events,
    p.total_approved * 100.0 / NULLIF(p.total_events, 0)             AS prev_approval_rate,
    p.total_declined * 100.0 / NULLIF(p.total_events, 0)             AS prev_decline_rate,
    p.avg_latency_ms                                                  AS prev_avg_latency_ms,
    f.last_serve_ts
FROM current_window c, previous_window p, freshness f;
