-- events.sql: Recent events from IT_AUTH_EVENT_SEARCH
-- Excludes headers and payload columns per display policy (Section 3.5.2)
-- Parameters: :auth_status, :payment_id, :env, :merchant_id, :limit_rows

SELECT
    event_ts,
    event_id,
    payment_id,
    env,
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
FROM PAYMENTS_DB.SERVE.IT_AUTH_EVENT_SEARCH
WHERE (%(auth_status)s IS NULL OR auth_status = %(auth_status)s)
  AND (%(payment_id)s IS NULL OR payment_id = %(payment_id)s)
  AND (%(env)s IS NULL OR env = %(env)s)
  AND (%(merchant_id)s IS NULL OR merchant_id = %(merchant_id)s)
ORDER BY event_ts DESC
LIMIT %(limit_rows)s;
