# Kafka Configuration

## Topic: `payments.auth`

Shared Kafka topic for all payment authorization events across all environments (dev, preprod, prod). Events are tagged with an `env` field to distinguish environments.

### Topic Configuration

| Property | Value | Rationale |
|---|---|---|
| Topic name | `payments.auth` | Single shared topic for all environments |
| Partitions | 24 | Supports 2000 events/sec peak with headroom |
| Replication factor | 3 | Standard HA for production clusters |
| `retention.ms` | 259200000 (72 hours) | 3-day replay window for recovery |
| `cleanup.policy` | `delete` | Time-based retention, no compaction |
| `compression.type` | `zstd` | Matches producer compression |

### Partitioning Strategy

- **Key**: `merchant_id` — provides partition affinity so all events for a given merchant land on the same partition, enabling ordered processing per merchant.
- 24 partitions balances parallelism across Kafka Connect tasks (1 task per partition).

### Throughput Design

| Metric | Value |
|---|---|
| Baseline rate | 500–1000 events/sec (combined across all environments) |
| Peak rate | 2000 events/sec |
| Avg event size | ~500 bytes JSON |
| Peak throughput | ~1 MB/sec |

### Consumer Group

- **`snowflake-hp-sink-payments`** — used by the Snowflake HP Kafka connector (primary ingest path)
- **`snowflake-fallback-relay`** — used by the Python batch fallback relay

---

## Creating the Topic

### Self-Managed Kafka

```bash
kafka-topics.sh --create \
  --bootstrap-server <broker>:9092 \
  --topic payments.auth \
  --partitions 24 \
  --replication-factor 3 \
  --config retention.ms=259200000 \
  --config cleanup.policy=delete \
  --config compression.type=zstd
```

Verify:

```bash
kafka-topics.sh --describe \
  --bootstrap-server <broker>:9092 \
  --topic payments.auth
```

### Confluent Cloud

```bash
confluent kafka topic create payments.auth \
  --partitions 24 \
  --config retention.ms=259200000 \
  --config cleanup.policy=delete
```

Or via the Confluent Cloud UI:
1. Navigate to your cluster → Topics → Add topic
2. Topic name: `payments.auth`
3. Partitions: 24
4. Set retention to 72 hours under Advanced settings

### Verify Accessibility

Confirm the topic is accessible from the Kafka Connect cluster:

```bash
kafka-console-consumer \
  --bootstrap-server <broker>:9092 \
  --topic payments.auth \
  --from-beginning \
  --max-messages 1 \
  --timeout-ms 5000
```

---

### Local Development

A `docker-compose.yml` is provided in the project root with an `apache/kafka:4.0.2` broker (KRaft mode, no Zookeeper). To start locally:

```bash
docker compose up -d kafka

# Create the topic
docker exec payments-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --create \
  --topic payments.auth \
  --partitions 24 \
  --replication-factor 1 \
  --config retention.ms=259200000 \
  --config cleanup.policy=delete

# Verify
docker exec payments-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --describe \
  --topic payments.auth
```
