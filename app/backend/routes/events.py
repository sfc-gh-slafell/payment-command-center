"""GET /api/v1/events — recent events from IT_AUTH_EVENT_SEARCH."""

from fastapi import APIRouter, Query
from pydantic import BaseModel

router = APIRouter()


class EventRow(BaseModel):
    event_ts: str
    event_id: str
    payment_id: str
    env: str
    merchant_id: str
    merchant_name: str
    region: str
    country: str
    card_brand: str
    issuer_bin: str
    payment_method: str
    amount: float
    currency: str
    auth_status: str
    decline_code: str | None = None
    auth_latency_ms: float


class EventsResponse(BaseModel):
    events: list[EventRow] = []
    total_count: int = 0


@router.get("/api/v1/events", response_model=EventsResponse)
async def get_events(
    auth_status: str | None = None,
    payment_id: str | None = None,
    env: str | None = None,
    merchant_id: str | None = None,
    limit_rows: int = Query(100, le=500),
):
    from main import get_client
    from pathlib import Path

    client = get_client()

    sql = Path(__file__).parent.parent.joinpath("queries", "events.sql").read_text()
    params = {
        "auth_status": auth_status,
        "payment_id": payment_id,
        "env": env,
        "merchant_id": merchant_id,
        "limit_rows": limit_rows,
    }
    rows = client.execute_query(sql, params)
    events = [
        EventRow(
            event_ts=str(r["EVENT_TS"]),
            event_id=r["EVENT_ID"],
            payment_id=r["PAYMENT_ID"],
            env=r["ENV"],
            merchant_id=r["MERCHANT_ID"],
            merchant_name=r["MERCHANT_NAME"],
            region=r["REGION"],
            country=r["COUNTRY"],
            card_brand=r["CARD_BRAND"],
            issuer_bin=r["ISSUER_BIN"],
            payment_method=r["PAYMENT_METHOD"],
            amount=r["AMOUNT"],
            currency=r["CURRENCY"],
            auth_status=r["AUTH_STATUS"],
            decline_code=r.get("DECLINE_CODE"),
            auth_latency_ms=r["AUTH_LATENCY_MS"],
        )
        for r in rows
    ]
    return EventsResponse(events=events, total_count=len(events))
