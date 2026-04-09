-- latency.sql: Histogram buckets from IT_AUTH_MINUTE_METRICS + percentiles from IT_AUTH_EVENT_SEARCH
-- Part 1: Histogram buckets (run on interactive WH)
-- Parameters: :time_range_minutes, :env, :merchant_id, :region

SELECT
    SUM(latency_0_50ms)       AS bucket_0_50ms,
    SUM(latency_50_100ms)     AS bucket_50_100ms,
    SUM(latency_100_200ms)    AS bucket_100_200ms,
    SUM(latency_200_500ms)    AS bucket_200_500ms,
    SUM(latency_500_1000ms)   AS bucket_500_1000ms,
    SUM(latency_1000ms_plus)  AS bucket_1000ms_plus,
    SUM(latency_sum_ms) / NULLIF(SUM(latency_count), 0) AS avg_latency_ms,
    MIN(latency_sum_ms / NULLIF(latency_count, 0))      AS min_latency_ms,
    MAX(latency_sum_ms / NULLIF(latency_count, 0))       AS max_latency_ms,
    SUM(latency_count)                                    AS event_count
FROM PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS
WHERE event_minute >= DATEADD('MINUTE', -%(time_range_minutes)s, SYSDATE())
  AND (%(env)s IS NULL OR env = %(env)s)
  AND (%(merchant_id)s IS NULL OR merchant_id = %(merchant_id)s)
  AND (%(region)s IS NULL OR region = %(region)s);

-- Part 2: Percentiles from event search (run separately, max_limit cap)
-- Parameters: :time_range_minutes, :env, :max_limit

SELECT
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY auth_latency_ms) AS p50,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY auth_latency_ms) AS p95,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY auth_latency_ms) AS p99
FROM (
    SELECT auth_latency_ms
    FROM PAYMENTS_DB.SERVE.IT_AUTH_EVENT_SEARCH
    WHERE event_ts >= DATEADD('MINUTE', -%(time_range_minutes)s, SYSDATE())
      AND (%(env)s IS NULL OR env = %(env)s)
    ORDER BY event_ts DESC
    LIMIT %(max_limit)s
);
