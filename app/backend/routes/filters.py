"""GET /api/v1/filters — populate filter dropdowns."""

from fastapi import APIRouter, Depends
from pydantic import BaseModel

router = APIRouter()


class FiltersResponse(BaseModel):
    envs: list[str] = []
    merchant_ids: list[str] = []
    merchant_names: list[str] = []
    regions: list[str] = []
    countries: list[str] = []
    card_brands: list[str] = []
    issuer_bins: list[str] = []
    payment_methods: list[str] = []


@router.get("/api/v1/filters", response_model=FiltersResponse)
async def get_filters():
    from main import get_client
    client = get_client()
    from pathlib import Path
    sql = Path(__file__).parent.parent.joinpath("queries", "filters.sql").read_text()
    rows = client.execute_query(sql)
    if rows:
        row = rows[0]
        return FiltersResponse(
            envs=row.get("ENVS") or [],
            merchant_ids=row.get("MERCHANT_IDS") or [],
            merchant_names=row.get("MERCHANT_NAMES") or [],
            regions=row.get("REGIONS") or [],
            countries=row.get("COUNTRIES") or [],
            card_brands=row.get("CARD_BRANDS") or [],
            issuer_bins=row.get("ISSUER_BINS") or [],
            payment_methods=row.get("PAYMENT_METHODS") or [],
        )
    return FiltersResponse()
