"""GET /api/v1/latency — histogram and percentile analysis."""

from fastapi import APIRouter, Query
from pydantic import BaseModel

router = APIRouter()


class HistogramBucket(BaseModel):
    label: str
    count: int


class LatencyStats(BaseModel):
    avg: float | None = None
    min: float | None = None
    max: float | None = None
    p50: float | None = None
    p95: float | None = None
    p99: float | None = None
    event_count: int = 0


class LatencyResponse(BaseModel):
    histogram: list[HistogramBucket] = []
    statistics: LatencyStats = LatencyStats()


@router.get("/api/v1/latency", response_model=LatencyResponse)
async def get_latency(
    time_range: int = Query(15, description="Time range in minutes"),
    env: str | None = None,
    merchant_id: str | None = None,
    region: str | None = None,
    max_limit: int = Query(10000, description="Max events for percentile calculation"),
):
    from main import get_client
    client = get_client()

    # Part 1: Histogram from IT_AUTH_MINUTE_METRICS
    histogram_sql = """
    SELECT
        SUM(latency_0_50ms)       AS bucket_0_50ms,
        SUM(latency_50_100ms)     AS bucket_50_100ms,
        SUM(latency_100_200ms)    AS bucket_100_200ms,
        SUM(latency_200_500ms)    AS bucket_200_500ms,
        SUM(latency_500_1000ms)   AS bucket_500_1000ms,
        SUM(latency_1000ms_plus)  AS bucket_1000ms_plus,
        SUM(latency_sum_ms) / NULLIF(SUM(latency_count), 0) AS avg_latency_ms,
        SUM(latency_count)        AS event_count
    FROM PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS
    WHERE event_minute >= DATEADD('MINUTE', -%(time_range_minutes)s, CURRENT_TIMESTAMP())
      AND (%(env)s IS NULL OR env = %(env)s)
      AND (%(merchant_id)s IS NULL OR merchant_id = %(merchant_id)s)
      AND (%(region)s IS NULL OR region = %(region)s)
    """
    hist_rows = client.execute_query(histogram_sql, {
        "time_range_minutes": time_range,
        "env": env,
        "merchant_id": merchant_id,
        "region": region,
    })

    histogram = []
    stats = LatencyStats()
    if hist_rows:
        r = hist_rows[0]
        bucket_labels = [
            ("0-50ms", "BUCKET_0_50MS"),
            ("50-100ms", "BUCKET_50_100MS"),
            ("100-200ms", "BUCKET_100_200MS"),
            ("200-500ms", "BUCKET_200_500MS"),
            ("500ms-1s", "BUCKET_500_1000MS"),
            (">1s", "BUCKET_1000MS_PLUS"),
        ]
        histogram = [
            HistogramBucket(label=label, count=r.get(col) or 0)
            for label, col in bucket_labels
        ]
        stats.avg = r.get("AVG_LATENCY_MS")
        stats.event_count = r.get("EVENT_COUNT") or 0

    # Part 2: Percentiles from IT_AUTH_EVENT_SEARCH (capped by max_limit)
    percentile_sql = """
    SELECT
        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY auth_latency_ms) AS p50,
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY auth_latency_ms) AS p95,
        PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY auth_latency_ms) AS p99,
        MIN(auth_latency_ms) AS min_val,
        MAX(auth_latency_ms) AS max_val
    FROM (
        SELECT auth_latency_ms
        FROM PAYMENTS_DB.SERVE.IT_AUTH_EVENT_SEARCH
        WHERE event_ts >= DATEADD('MINUTE', -%(time_range_minutes)s, CURRENT_TIMESTAMP())
          AND (%(env)s IS NULL OR env = %(env)s)
        ORDER BY event_ts DESC
        LIMIT %(max_limit)s
    )
    """
    try:
        pct_rows = client.execute_query(percentile_sql, {
            "time_range_minutes": time_range,
            "env": env,
            "max_limit": max_limit,
        })
        if pct_rows:
            pr = pct_rows[0]
            stats.p50 = pr.get("P50")
            stats.p95 = pr.get("P95")
            stats.p99 = pr.get("P99")
            stats.min = pr.get("MIN_VAL")
            stats.max = pr.get("MAX_VAL")
    except Exception:
        pass  # Percentiles are best-effort

    return LatencyResponse(histogram=histogram, statistics=stats)
