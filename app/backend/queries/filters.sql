-- filters.sql: Distinct values for dropdown population
-- Run on interactive WH against IT_AUTH_MINUTE_METRICS

SELECT
    ARRAY_AGG(DISTINCT env) AS envs,
    ARRAY_AGG(DISTINCT merchant_id) AS merchant_ids,
    ARRAY_AGG(DISTINCT merchant_name) AS merchant_names,
    ARRAY_AGG(DISTINCT region) AS regions,
    ARRAY_AGG(DISTINCT country) AS countries,
    ARRAY_AGG(DISTINCT card_brand) AS card_brands,
    ARRAY_AGG(DISTINCT issuer_bin) AS issuer_bins,
    ARRAY_AGG(DISTINCT payment_method) AS payment_methods
FROM PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS
WHERE event_minute >= DATEADD('HOUR', -24, CURRENT_TIMESTAMP());
