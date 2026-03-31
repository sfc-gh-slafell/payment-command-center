---
name: kafka-producer-python
description: Python Kafka producer patterns with confluent_kafka for event generation and Docker Compose networking. Use when implementing Kafka producers, troubleshooting connection issues, or designing event generation services.
---

# Kafka Producer with Python (confluent_kafka)

## Purpose

Document patterns for implementing Kafka producers with `confluent_kafka` Python library, including Docker networking, topic management, and FastAPI integration for controllable event generation.

## Python Producer Configuration

### Basic Producer Setup

```python
from confluent_kafka import Producer

def create_producer() -> Producer:
    """Create a Kafka producer with optimized settings."""
    return Producer({
        "bootstrap.servers": "kafka:29092",  # Docker internal hostname
        "compression.type": "zstd",
        "acks": "all",                       # Wait for all replicas
        "linger.ms": 5,                      # Batch window
        "batch.size": 16384,                 # 16KB batches
        "message.max.bytes": 10485760,       # 10MB limit (match broker)
    })
```

**Key configuration parameters:**

| Parameter | Recommended Value | Purpose |
|-----------|------------------|---------|
| `bootstrap.servers` | `kafka:29092` (Docker) or `localhost:9092` (host) | Kafka broker addresses |
| `compression.type` | `zstd` or `lz4` | Compress batches for network efficiency |
| `acks` | `all` or `1` | Acknowledgment level (all = most durable) |
| `linger.ms` | `5-10` | Batching window for throughput |
| `message.max.bytes` | Match broker limit | Prevent rejection of large messages |

### Producing Messages

```python
import json

def send_event(producer: Producer, topic: str, event: dict):
    """Send a single event to Kafka topic."""
    producer.produce(
        topic,
        key=event.get("event_id"),           # Optional key for partitioning
        value=json.dumps(event).encode('utf-8'),
        callback=delivery_callback
    )
    # Don't call flush() on every message - let batching work

def delivery_callback(err, msg):
    """Callback for delivery reports."""
    if err:
        print(f'Message delivery failed: {err}')
    else:
        print(f'Message delivered to {msg.topic()} [{msg.partition()}] @ offset {msg.offset()}')

# Flush at end of batch or shutdown
producer.flush(timeout=10)
```

## Docker Compose Networking

### Critical Pattern: Container-to-Container Communication

**Problem:** Containers cannot connect to `localhost:9092` — that resolves to the container's own loopback, not the Kafka broker.

**Solution:** Use internal Docker network hostname and listener.

### Docker Compose Configuration

```yaml
services:
  kafka:
    image: apache/kafka:4.0.2
    container_name: payments-kafka
    ports:
      - "9092:9092"      # Host access
    environment:
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092,INTERNAL://0.0.0.0:29092
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://localhost:9092,INTERNAL://kafka:29092
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,INTERNAL:PLAINTEXT

  producer:
    build: ./producer
    container_name: payments-generator
    environment:
      # CRITICAL: Use internal listener (kafka:29092), NOT localhost:9092
      KAFKA_BOOTSTRAP_SERVERS: "kafka:29092"
      KAFKA_TOPIC: "payments.auth"
    depends_on:
      - kafka
```

**Listener Strategy:**
- `PLAINTEXT://0.0.0.0:9092` → Bind to all interfaces on port 9092
- `INTERNAL://0.0.0.0:29092` → Bind to all interfaces on port 29092
- `localhost:9092` → Advertised for host machine access
- `kafka:29092` → Advertised for container-to-container access

### Environment Variable Configuration

```python
# config.py
import os

BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
TOPIC = os.getenv("KAFKA_TOPIC", "payments.auth")
```

**Default fallback values:**
- Development (host machine): `localhost:9092`
- Production (Docker): Override with `KAFKA_BOOTSTRAP_SERVERS=kafka:29092`

## Topic Management

### Creating Topics

```bash
# Via docker exec
docker exec payments-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka:29092 \
  --create \
  --topic payments.auth \
  --partitions 24 \
  --replication-factor 1 \
  --config max.message.bytes=10485760

# List topics
docker exec payments-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka:29092 \
  --list

# Describe topic (check partition count)
docker exec payments-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka:29092 \
  --describe \
  --topic payments.auth
```

### Partition Scaling

**Important:** Topic partition count determines max parallelism for consumers/connectors.

```bash
# Increase partitions (cannot decrease)
docker exec payments-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka:29092 \
  --alter \
  --topic payments.auth \
  --partitions 24
```

**Best practice:** Align partition count with:
- Expected max consumer instances
- Snowflake connector `tasks.max` setting
- Throughput requirements (more partitions = more parallelism)

## FastAPI Integration for Controllable Generation

### Service Architecture

```python
# main.py
from fastapi import FastAPI
from pydantic import BaseModel
from producer import create_producer, generate_event
import asyncio

class RateRequest(BaseModel):
    events_per_sec: int

state = {
    "producer": None,
    "rate": 500,
    "event_count": 0,
}

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    state["producer"] = create_producer()
    asyncio.create_task(producer_loop())
    yield
    # Shutdown
    state["producer"].flush()

app = FastAPI(lifespan=lifespan)

async def producer_loop():
    """Background task producing events at configured rate."""
    producer = state["producer"]
    while True:
        event = generate_event()
        producer.produce(TOPIC, value=json.dumps(event).encode('utf-8'))
        state["event_count"] += 1
        await asyncio.sleep(1.0 / state["rate"])

@app.post("/rate")
def set_rate(req: RateRequest):
    state["rate"] = req.events_per_sec
    return {"rate": state["rate"]}

@app.get("/status")
def get_status():
    return {
        "events_per_sec": state["rate"],
        "total_events": state["event_count"],
    }
```

### Docker Compose Service

```yaml
  generator:
    build:
      context: generator
      dockerfile: Dockerfile
    container_name: payments-generator
    ports:
      - "8001:8000"  # Avoid port conflicts
    environment:
      KAFKA_BOOTSTRAP_SERVERS: "kafka:29092"
      KAFKA_TOPIC: "payments.auth"
      GENERATOR_RATE: "500"
      GENERATOR_ENV: "dev"
    depends_on:
      - kafka
    command: ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

## Troubleshooting

### Check Consumer Group Lag

```bash
# View consumer group offset and lag
docker exec payments-kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server kafka:29092 \
  --group connect-auth-events-sink-payments \
  --describe
```

**Output interpretation:**
- `CURRENT-OFFSET`: Last offset committed by consumer
- `LOG-END-OFFSET`: Latest message in topic
- `LAG`: Messages waiting to be consumed (0 = caught up)

### Manual Message Consumption

```bash
# Consume from beginning (testing)
docker exec payments-kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka:29092 \
  --topic payments.auth \
  --from-beginning \
  --timeout-ms 5000 \
  --max-messages 10
```

### Connection Troubleshooting

```bash
# Check producer container logs for connection errors
docker logs payments-generator --tail 50 | grep -E "(FAIL|Connect|refused)"

# Expected error pattern if using wrong bootstrap server:
# %3|FAIL|rdkafka#producer-1| localhost:9092/bootstrap: Connect to ipv4#127.0.0.1:9092 failed: Connection refused
```

## Common Pitfalls

1. **Connection refused to localhost:9092 from container** — Using `localhost` instead of Docker network hostname. Container's localhost is its own network namespace, not the host machine. Solution: Use `kafka:29092` for container-to-container communication.

2. **Port conflict on 8000** — Another service already bound to port 8000. Solution: Map to different host port in docker-compose (e.g., `8001:8000`).

3. **Producer hangs on flush()** — Kafka broker unreachable or wrong bootstrap server. Check network connectivity and ensure using correct listener (internal vs external).

4. **Messages too large** — Producer `message.max.bytes` exceeds broker `max.message.bytes`. Solution: Align both settings (default 10MB = 10485760 bytes).

5. **Low throughput despite high rate** — Missing batching configuration. Solution: Set `linger.ms` (5-10ms) and `batch.size` (16KB+) to enable efficient batching.

6. **Consumer lag growing** — Producer rate exceeds consumer capacity. Solution: Increase topic partitions and consumer/connector task count for parallel processing.

7. **Network name resolution fails** — Container cannot resolve `kafka` hostname. Verify containers are on same Docker network with `docker network inspect <network-name>`.

8. **Generator API not responding** — Wrong port mapping or container not started. Check `docker ps` and verify port mapping matches curl target (e.g., `localhost:8001` if mapped `8001:8000`).

## Message Rate Control

### Dynamic Rate Adjustment

```bash
# Start at 500 events/sec
curl -X POST http://localhost:8001/rate -H "Content-Type: application/json" -d '{"events_per_sec": 500}'

# Increase to 1000 events/sec
curl -X POST http://localhost:8001/rate -H "Content-Type: application/json" -d '{"events_per_sec": 1000}'

# Check current status
curl http://localhost:8001/status
```

### Monitoring Production

```python
# Add periodic metrics logging to producer_loop
async def producer_loop():
    last_report = time.time()
    while True:
        event = generate_event()
        producer.produce(TOPIC, value=json.dumps(event).encode('utf-8'))
        state["event_count"] += 1

        # Report every 10 seconds
        now = time.time()
        if now - last_report >= 10:
            producer.flush()  # Ensure delivery
            print(f"Produced {state['event_count']} events, rate: {state['rate']}/sec")
            last_report = now

        await asyncio.sleep(1.0 / state["rate"])
```

## Quick Reference

```bash
# Start full stack
docker-compose up -d kafka generator

# Check generator status
curl http://localhost:8001/status

# Monitor consumer lag
docker exec payments-kafka /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server kafka:29092 \
  --group connect-auth-events-sink-payments \
  --describe

# View topic partition details
docker exec payments-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka:29092 \
  --describe \
  --topic payments.auth

# Increase topic partitions
docker exec payments-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka:29092 \
  --alter \
  --topic payments.auth \
  --partitions 24
```
