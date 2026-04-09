-- timeseries.sql: Minute-bucketed metrics for time series chart
-- Parameters: :time_range_minutes, :env, :merchant_id, :region, :card_brand

SELECT
    event_minute,
    SUM(event_count)                                       AS event_count,
    SUM(decline_count) * 100.0 / NULLIF(SUM(event_count), 0) AS decline_rate,
    SUM(latency_sum_ms) / NULLIF(SUM(latency_count), 0)   AS avg_latency_ms
FROM PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS
WHERE event_minute >= DATEADD('MINUTE', -%(time_range_minutes)s, SYSDATE())
  AND (%(env)s IS NULL OR env = %(env)s)
  AND (%(merchant_id)s IS NULL OR merchant_id = %(merchant_id)s)
  AND (%(region)s IS NULL OR region = %(region)s)
  AND (%(card_brand)s IS NULL OR card_brand = %(card_brand)s)
GROUP BY event_minute
ORDER BY event_minute
LIMIT 1000;
