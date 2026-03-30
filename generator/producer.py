"""Kafka producer and event generation for payment authorization events."""

import random
import time
import uuid
from datetime import datetime, timezone

from confluent_kafka import Producer

from catalog import MERCHANTS, BINS, REGIONS, PAYMENT_METHODS, DECLINE_CODES
from config import BOOTSTRAP_SERVERS, TOPIC, DEFAULT_ENV


def create_producer() -> Producer:
    """Create a Kafka producer with optimized settings."""
    return Producer({
        "bootstrap.servers": BOOTSTRAP_SERVERS,
        "compression.type": "zstd",
        "acks": "all",
        "linger.ms": 5,
        "batch.size": 16384,
    })


def generate_event(env: str = DEFAULT_ENV, rng: random.Random | None = None) -> dict:
    """Generate a single payment authorization event matching the spec schema."""
    r = rng or random

    merchant = r.choice(MERCHANTS)
    bin_entry = r.choice(BINS)
    region = r.choice(list(REGIONS.keys()))
    country = r.choice(REGIONS[region])
    payment_method = r.choice(PAYMENT_METHODS)

    # Baseline: ~95% approval, 50-150ms latency
    is_approved = r.random() < 0.95
    auth_status = "APPROVED" if is_approved else r.choice(["DECLINED", "ERROR", "TIMEOUT"])
    decline_code = None if is_approved else r.choice(DECLINE_CODES)
    auth_latency_ms = round(r.uniform(50, 150), 1)
    amount = round(r.uniform(1.00, 5000.00), 2)

    return {
        "env": env,
        "event_ts": datetime.now(timezone.utc).isoformat(),
        "event_id": str(uuid.uuid4()),
        "payment_id": f"PAY-{uuid.uuid4().hex[:12].upper()}",
        "merchant_id": merchant["merchant_id"],
        "merchant_name": merchant["merchant_name"],
        "region": region,
        "country": country,
        "card_brand": bin_entry["card_brand"],
        "issuer_bin": bin_entry["issuer_bin"],
        "payment_method": payment_method,
        "amount": amount,
        "currency": "USD",
        "auth_status": auth_status,
        "decline_code": decline_code,
        "auth_latency_ms": auth_latency_ms,
    }


def produce_event(producer: Producer, event: dict) -> None:
    """Send an event to Kafka using merchant_id as the key for partition affinity."""
    import json

    producer.produce(
        topic=TOPIC,
        key=event["merchant_id"],
        value=json.dumps(event).encode("utf-8"),
    )


def run_producer_loop(producer: Producer, rate: int, env: str, stop_event=None):
    """Produce events at the given rate until stop_event is set."""
    interval = 1.0 / rate if rate > 0 else 1.0
    while stop_event is None or not stop_event.is_set():
        event = generate_event(env=env)
        produce_event(producer, event)
        producer.poll(0)
        time.sleep(interval)
    producer.flush()
