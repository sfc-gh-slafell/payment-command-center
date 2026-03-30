"""FastAPI dashboard backend with dual Snowflake connection pools."""

from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from snowflake_client import SnowflakeClient

_client: SnowflakeClient | None = None


def get_client() -> SnowflakeClient:
    assert _client is not None, "Snowflake client not initialized"
    return _client


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _client
    _client = SnowflakeClient()
    yield
    _client.close()
    _client = None


app = FastAPI(title="Payment Command Center API", lifespan=lifespan)

# CORS for local development
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Register route handlers
from routes.filters import router as filters_router
from routes.summary import router as summary_router
from routes.timeseries import router as timeseries_router
from routes.breakdown import router as breakdown_router
from routes.events import router as events_router
from routes.latency import router as latency_router

app.include_router(filters_router)
app.include_router(summary_router)
app.include_router(timeseries_router)
app.include_router(breakdown_router)
app.include_router(events_router)
app.include_router(latency_router)


@app.get("/health")
async def health():
    """Health check returning connection pool status."""
    status = _client.health_check() if _client else {"interactive": "not initialized", "standard": "not initialized"}
    return {"status": "ok" if all(v == "ok" for v in status.values()) else "degraded", "pools": status}


# Serve frontend static files (built React app)
static_dir = Path(__file__).parent.parent / "frontend" / "dist"
if static_dir.exists():
    app.mount("/", StaticFiles(directory=str(static_dir), html=True), name="static")
