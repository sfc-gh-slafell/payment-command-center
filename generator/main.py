"""FastAPI control API for the payment event generator."""

import asyncio
import json
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI
from pydantic import BaseModel

from config import BOOTSTRAP_SERVERS, TOPIC, DEFAULT_RATE, DEFAULT_ENV
from producer import create_producer, generate_event
from scenarios import SCENARIOS, Baseline


class ScenarioRequest(BaseModel):
    profile: str
    duration_sec: int = 300


class RateRequest(BaseModel):
    events_per_sec: int


# --- State ---
state = {
    "producer": None,
    "scenario": Baseline(),
    "rate": DEFAULT_RATE,
    "env": DEFAULT_ENV,
    "start_time": None,
    "event_count": 0,
    "scenario_task": None,
}


async def producer_loop():
    """Background task that produces events at the configured rate."""
    producer = state["producer"]
    while True:
        rate = state["rate"]
        interval = 1.0 / rate if rate > 0 else 1.0
        event = generate_event(env=state["env"])
        event = state["scenario"].modify_event(event)
        producer.produce(
            topic=TOPIC,
            key=event["merchant_id"],
            value=json.dumps(event).encode("utf-8"),
        )
        producer.poll(0)
        state["event_count"] += 1
        await asyncio.sleep(interval)


async def auto_return_to_baseline(duration_sec: int):
    """Return to baseline after duration expires."""
    await asyncio.sleep(duration_sec)
    state["scenario"] = Baseline()
    state["scenario_task"] = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    state["producer"] = create_producer()
    state["start_time"] = time.time()
    task = asyncio.create_task(producer_loop())
    yield
    task.cancel()
    if state["producer"]:
        state["producer"].flush()


app = FastAPI(title="Payment Event Generator", lifespan=lifespan)


@app.get("/status")
async def get_status():
    uptime = time.time() - state["start_time"] if state["start_time"] else 0
    return {
        "scenario": state["scenario"].name,
        "events_per_sec": state["rate"],
        "env": state["env"],
        "total_events": state["event_count"],
        "uptime_sec": round(uptime, 1),
    }


@app.post("/scenario")
async def set_scenario(req: ScenarioRequest):
    if req.profile not in SCENARIOS:
        return {"error": f"Unknown profile: {req.profile}", "available": list(SCENARIOS.keys())}

    # Cancel any existing duration timer
    if state["scenario_task"] is not None:
        state["scenario_task"].cancel()

    state["scenario"] = SCENARIOS[req.profile]()

    # Auto-return to baseline after duration
    state["scenario_task"] = asyncio.create_task(auto_return_to_baseline(req.duration_sec))

    return {"profile": req.profile, "duration_sec": req.duration_sec}


@app.delete("/scenario")
async def clear_scenario():
    if state["scenario_task"] is not None:
        state["scenario_task"].cancel()
        state["scenario_task"] = None
    state["scenario"] = Baseline()
    return {"profile": "baseline"}


@app.post("/rate")
async def set_rate(req: RateRequest):
    state["rate"] = req.events_per_sec
    return {"events_per_sec": req.events_per_sec}
