"""FastAPI control API for the payment event generator."""

import asyncio
import json
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import FastAPI
from pydantic import BaseModel

from config import TOPIC, DEFAULT_RATE, DEFAULT_ENV
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


_TICK_HZ = 10  # produce in fixed-size batches 10× per second

_POOL_SIZE = 50_000        # pre-generated event dicts — reused each tick
_event_pool: list[dict] = []
_pool_idx: int = 0


async def producer_loop():
    """Background task that produces events at the configured rate.

    Uses a batch-tick pattern rather than per-event asyncio.sleep() to achieve
    accurate high-rate production. asyncio.sleep() has a minimum resolution of
    ~1 ms on most systems; sleeping 1/rate seconds per event is unreliable above
    ~500 rps and causes a ~37% rate undershoot at the default 500 rps target.

    Instead, we sleep a reliable 100 ms (1/_TICK_HZ) and produce rate//_TICK_HZ
    events per tick, yielding actual throughput within ~5% of the configured rate
    at any target rate.

    Hot-loop optimisations to sustain ≥50k rps in Python:
    - Shallow-copy events from a pre-generated pool (_event_pool) to avoid
      calling generate_event() (uuid4 + random choices) on every event.
    - Stamp event_ts once per tick (not per event) — 100 ms resolution is
      finer than the 1-second dashboard bucket so accuracy is unaffected.
    - Serialize JSON once and reuse the bytes for the topic.produce() call.
    """
    global _pool_idx
    producer = state["producer"]
    while True:
        rate = state["rate"]
        batch_size = max(1, rate // _TICK_HZ)
        tick_ts = datetime.now(timezone.utc).isoformat()  # once per tick
        for _ in range(batch_size):
            event = dict(_event_pool[_pool_idx % _POOL_SIZE])  # shallow copy
            _pool_idx += 1
            event["event_ts"] = tick_ts
            event = state["scenario"].modify_event(event)
            value = json.dumps(event).encode("utf-8")  # serialize once
            key = event["merchant_id"]
            try:
                producer.produce(topic=TOPIC, key=key, value=value)
            except BufferError:
                # Queue full — drain delivery callbacks and retry once
                producer.poll(1.0)
                producer.produce(topic=TOPIC, key=key, value=value)
        producer.poll(0)
        state["event_count"] += batch_size
        await asyncio.sleep(1.0 / _TICK_HZ)


async def auto_return_to_baseline(duration_sec: int):
    """Return to baseline after duration expires."""
    await asyncio.sleep(duration_sec)
    state["scenario"] = Baseline()
    state["scenario_task"] = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _event_pool
    state["producer"] = create_producer()
    state["start_time"] = time.time()
    # Pre-generate the event pool (~1 s startup cost; amortised across all ticks)
    _event_pool = [generate_event(env=state["env"]) for _ in range(_POOL_SIZE)]
    task = asyncio.create_task(producer_loop())

    def _on_task_done(t: asyncio.Task) -> None:
        if not t.cancelled() and t.exception():
            import traceback
            print(f"[ERROR] producer_loop crashed: {t.exception()}")
            traceback.print_exception(type(t.exception()), t.exception(),
                                      t.exception().__traceback__)

    task.add_done_callback(_on_task_done)
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
        return {
            "error": f"Unknown profile: {req.profile}",
            "available": list(SCENARIOS.keys()),
        }

    # Cancel any existing duration timer
    if state["scenario_task"] is not None:
        state["scenario_task"].cancel()

    state["scenario"] = SCENARIOS[req.profile]()

    # Auto-return to baseline after duration
    state["scenario_task"] = asyncio.create_task(
        auto_return_to_baseline(req.duration_sec)
    )

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
