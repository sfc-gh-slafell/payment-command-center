"""GET /api/v1/summary — KPI summary with freshness."""

from fastapi import APIRouter, Query
from pydantic import BaseModel

router = APIRouter()


class FreshnessInfo(BaseModel):
    last_raw_ts: str | None = None
    last_serve_ts: str | None = None


class SummaryResponse(BaseModel):
    current_events: int | None = None
    current_approval_rate: float | None = None
    current_decline_rate: float | None = None
    current_avg_latency_ms: float | None = None
    prev_events: int | None = None
    prev_approval_rate: float | None = None
    prev_decline_rate: float | None = None
    prev_avg_latency_ms: float | None = None
    freshness: FreshnessInfo = FreshnessInfo()


@router.get("/api/v1/summary", response_model=SummaryResponse)
async def get_summary(
    time_range: int = Query(15, description="Time range in minutes"),
    env: str | None = None,
    merchant_id: str | None = None,
    region: str | None = None,
    card_brand: str | None = None,
):
    from main import get_client
    from pathlib import Path

    client = get_client()

    sql = Path(__file__).parent.parent.joinpath("queries", "summary.sql").read_text()
    params = {
        "time_range_minutes": time_range,
        "env": env,
        "merchant_id": merchant_id,
        "region": region,
        "card_brand": card_brand,
    }
    rows = client.execute_query(sql, params)

    # Freshness: MAX(ingested_at) from RAW via standard warehouse
    freshness = FreshnessInfo()
    try:
        raw_rows = client.execute_query(
            "SELECT MAX(ingested_at) AS last_raw_ts FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW",
            use_standard_wh=True,
        )
        if raw_rows and raw_rows[0].get("LAST_RAW_TS"):
            freshness.last_raw_ts = str(raw_rows[0]["LAST_RAW_TS"])
    except Exception:
        pass

    if rows:
        row = rows[0]
        freshness.last_serve_ts = str(row.get("LAST_SERVE_TS") or "")
        return SummaryResponse(
            current_events=row.get("CURRENT_EVENTS"),
            current_approval_rate=row.get("CURRENT_APPROVAL_RATE"),
            current_decline_rate=row.get("CURRENT_DECLINE_RATE"),
            current_avg_latency_ms=row.get("CURRENT_AVG_LATENCY_MS"),
            prev_events=row.get("PREV_EVENTS"),
            prev_approval_rate=row.get("PREV_APPROVAL_RATE"),
            prev_decline_rate=row.get("PREV_DECLINE_RATE"),
            prev_avg_latency_ms=row.get("PREV_AVG_LATENCY_MS"),
            freshness=freshness,
        )
    return SummaryResponse(freshness=freshness)
