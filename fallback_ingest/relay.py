"""Kafka consumer relay: consume events and batch-write to Snowflake."""

import json
import logging
import time

from confluent_kafka import Consumer, KafkaError

from config import (
    KAFKA_BOOTSTRAP_SERVERS,
    KAFKA_TOPIC,
    KAFKA_GROUP_ID,
    BATCH_SIZE,
    BATCH_TIMEOUT,
)
from sf_client import get_connection, write_batch

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)


def create_consumer() -> Consumer:
    return Consumer(
        {
            "bootstrap.servers": KAFKA_BOOTSTRAP_SERVERS,
            "group.id": KAFKA_GROUP_ID,
            "auto.offset.reset": "earliest",
            "enable.auto.commit": False,
            # Message size limits aligned with broker (10 MB)
            "fetch.max.bytes": 10485760,
            "max.partition.fetch.bytes": 10485760,
        }
    )


def parse_message(msg) -> dict | None:
    """Parse a Kafka message into a row dict with metadata columns."""
    try:
        event = json.loads(msg.value().decode("utf-8"))
        event["source_topic"] = msg.topic()
        event["source_partition"] = msg.partition()
        event["source_offset"] = msg.offset()
        return event
    except (json.JSONDecodeError, AttributeError):
        logger.warning("Failed to parse message at offset %s", msg.offset())
        return None


def run_relay():
    """Main consumer loop: accumulate batch, flush on size or time threshold, commit offsets."""
    consumer = create_consumer()
    consumer.subscribe([KAFKA_TOPIC])
    conn = get_connection()

    buffer: list[dict] = []
    last_flush = time.time()

    logger.info(
        "Relay started — consuming from %s, batch_size=%d, batch_timeout=%.1fs",
        KAFKA_TOPIC,
        BATCH_SIZE,
        BATCH_TIMEOUT,
    )

    try:
        while True:
            msg = consumer.poll(timeout=1.0)

            if msg is None:
                pass
            elif msg.error():
                if msg.error().code() != KafkaError._PARTITION_EOF:
                    logger.error("Consumer error: %s", msg.error())
            else:
                row = parse_message(msg)
                if row:
                    buffer.append(row)

            # Flush on batch size or timeout
            elapsed = time.time() - last_flush
            if len(buffer) >= BATCH_SIZE or (buffer and elapsed >= BATCH_TIMEOUT):
                write_batch(conn, buffer)
                consumer.commit(asynchronous=False)
                logger.info("Flushed %d rows, committed offsets", len(buffer))
                buffer.clear()
                last_flush = time.time()
    except KeyboardInterrupt:
        logger.info("Shutting down relay")
    finally:
        if buffer:
            write_batch(conn, buffer)
            consumer.commit(asynchronous=False)
        consumer.close()
        conn.close()


if __name__ == "__main__":
    run_relay()
