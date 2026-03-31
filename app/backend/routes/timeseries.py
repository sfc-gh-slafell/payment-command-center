"""GET /api/v1/timeseries — minute-bucketed time series data."""

from fastapi import APIRouter, Query
from pydantic import BaseModel

router = APIRouter()


class TimeseriesBucket(BaseModel):
    event_minute: str
    event_count: int
    decline_rate: float | None = None
    avg_latency_ms: float | None = None


class TimeseriesResponse(BaseModel):
    buckets: list[TimeseriesBucket] = []


@router.get("/api/v1/timeseries", response_model=TimeseriesResponse)
async def get_timeseries(
    time_range: int = Query(60, description="Time range in minutes"),
    env: str | None = None,
    merchant_id: str | None = None,
    region: str | None = None,
    card_brand: str | None = None,
):
    from main import get_client
    from pathlib import Path

    client = get_client()

    sql = Path(__file__).parent.parent.joinpath("queries", "timeseries.sql").read_text()
    params = {
        "time_range_minutes": time_range,
        "env": env,
        "merchant_id": merchant_id,
        "region": region,
        "card_brand": card_brand,
    }
    rows = client.execute_query(sql, params)
    buckets = [
        TimeseriesBucket(
            event_minute=str(r["EVENT_MINUTE"]),
            event_count=r["EVENT_COUNT"] or 0,
            decline_rate=r.get("DECLINE_RATE"),
            avg_latency_ms=r.get("AVG_LATENCY_MS"),
        )
        for r in rows
    ]
    return TimeseriesResponse(buckets=buckets)
