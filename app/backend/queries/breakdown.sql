-- breakdown.sql: Top-N dimension breakdown with delta vs previous period
-- Parameters: :dimension, :time_range_minutes, :env, :top_n

WITH current_period AS (
    SELECT
        %(dimension)s                                          AS dimension_value,
        SUM(event_count)                                       AS events,
        SUM(decline_count) * 100.0 / NULLIF(SUM(event_count), 0) AS decline_rate,
        SUM(latency_sum_ms) / NULLIF(SUM(latency_count), 0)   AS avg_latency_ms
    FROM PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS
    WHERE event_minute >= DATEADD('MINUTE', -%(time_range_minutes)s, SYSDATE())
      AND (%(env)s IS NULL OR env = %(env)s)
    GROUP BY %(dimension)s
),
previous_period AS (
    SELECT
        %(dimension)s                                          AS dimension_value,
        SUM(event_count)                                       AS events,
        SUM(decline_count) * 100.0 / NULLIF(SUM(event_count), 0) AS decline_rate,
        SUM(latency_sum_ms) / NULLIF(SUM(latency_count), 0)   AS avg_latency_ms
    FROM PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS
    WHERE event_minute >= DATEADD('MINUTE', -(%(time_range_minutes)s * 2), SYSDATE())
      AND event_minute < DATEADD('MINUTE', -%(time_range_minutes)s, SYSDATE())
      AND (%(env)s IS NULL OR env = %(env)s)
    GROUP BY %(dimension)s
)
SELECT
    c.dimension_value,
    c.events,
    c.decline_rate,
    c.avg_latency_ms,
    c.events - COALESCE(p.events, 0)                      AS events_delta,
    c.decline_rate - COALESCE(p.decline_rate, 0)           AS decline_rate_delta,
    c.avg_latency_ms - COALESCE(p.avg_latency_ms, 0)      AS latency_delta
FROM current_period c
LEFT JOIN previous_period p ON c.dimension_value = p.dimension_value
ORDER BY c.events DESC
LIMIT %(top_n)s;
