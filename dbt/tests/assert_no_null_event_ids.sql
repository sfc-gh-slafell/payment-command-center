-- Singular test: assert no null event_ids in enriched curated table
-- Returns rows where event_id is NULL (test fails if any rows returned)
SELECT
    event_id,
    event_ts,
    ingested_at
FROM {{ ref('dt_auth_enriched') }}
WHERE event_id IS NULL
