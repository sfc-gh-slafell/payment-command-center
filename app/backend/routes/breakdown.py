"""GET /api/v1/breakdown — dimension breakdown with deltas."""

from fastapi import APIRouter, Query
from pydantic import BaseModel

router = APIRouter()

VALID_DIMENSIONS = {"merchant_id", "region", "country", "card_brand", "issuer_bin"}


class BreakdownRow(BaseModel):
    dimension_value: str
    events: int
    decline_rate: float | None = None
    avg_latency_ms: float | None = None
    events_delta: int | None = None
    decline_rate_delta: float | None = None
    latency_delta: float | None = None


class BreakdownResponse(BaseModel):
    dimension: str
    rows: list[BreakdownRow] = []


@router.get("/api/v1/breakdown", response_model=BreakdownResponse)
async def get_breakdown(
    dimension: str = Query(..., description="Dimension to break down by"),
    time_range: int = Query(15, description="Time range in minutes"),
    env: str | None = None,
    top_n: int = Query(20, description="Top N results"),
):
    from main import get_client
    from pathlib import Path
    client = get_client()

    if dimension not in VALID_DIMENSIONS:
        return BreakdownResponse(dimension=dimension, rows=[])

    sql = Path(__file__).parent.parent.joinpath("queries", "breakdown.sql").read_text()
    # Replace dimension placeholder (safe — validated against whitelist)
    sql = sql.replace("%(dimension)s", dimension)
    params = {
        "time_range_minutes": time_range,
        "env": env,
        "top_n": top_n,
    }
    rows = client.execute_query(sql, params)
    return BreakdownResponse(
        dimension=dimension,
        rows=[
            BreakdownRow(
                dimension_value=str(r.get("DIMENSION_VALUE", "")),
                events=r.get("EVENTS", 0),
                decline_rate=r.get("DECLINE_RATE"),
                avg_latency_ms=r.get("AVG_LATENCY_MS"),
                events_delta=r.get("EVENTS_DELTA"),
                decline_rate_delta=r.get("DECLINE_RATE_DELTA"),
                latency_delta=r.get("LATENCY_DELTA"),
            )
            for r in rows
        ],
    )
