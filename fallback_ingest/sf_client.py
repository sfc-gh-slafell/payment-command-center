"""Snowflake connection and batch write helpers using key-pair auth."""

import logging
from pathlib import Path

import pandas as pd
import snowflake.connector
from snowflake.connector.pandas_tools import write_pandas

from config import (
    SNOWFLAKE_ACCOUNT,
    SNOWFLAKE_DATABASE,
    SNOWFLAKE_PRIVATE_KEY,
    SNOWFLAKE_PRIVATE_KEY_PATH,
    SNOWFLAKE_ROLE,
    SNOWFLAKE_SCHEMA,
    SNOWFLAKE_USER,
    SNOWFLAKE_WAREHOUSE,
)

logger = logging.getLogger(__name__)

# Columns in AUTH_EVENTS_RAW that the relay must populate,
# including Kafka metadata: source_topic, source_partition, source_offset.
TABLE_NAME = "AUTH_EVENTS_RAW"

COLUMNS = [
    "env",
    "event_ts",
    "event_id",
    "payment_id",
    "merchant_id",
    "merchant_name",
    "region",
    "country",
    "card_brand",
    "issuer_bin",
    "payment_method",
    "amount",
    "currency",
    "auth_status",
    "decline_code",
    "auth_latency_ms",
    "source_topic",
    "source_partition",
    "source_offset",
]


def _load_private_key() -> bytes:
    """Load the private key as DER bytes.

    Prefers SNOWFLAKE_PRIVATE_KEY (base64-encoded DER, same format as the V4
    Kafka connector's .env).  Falls back to SNOWFLAKE_PRIVATE_KEY_PATH (PEM
    file) for local dev outside Docker.
    """
    if SNOWFLAKE_PRIVATE_KEY:
        import base64
        return base64.b64decode(SNOWFLAKE_PRIVATE_KEY)

    if SNOWFLAKE_PRIVATE_KEY_PATH:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.backends import default_backend
        key_path = Path(SNOWFLAKE_PRIVATE_KEY_PATH)
        with open(key_path, "rb") as f:
            private_key = serialization.load_pem_private_key(
                f.read(), password=None, backend=default_backend()
            )
        return private_key.private_bytes(
            encoding=serialization.Encoding.DER,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )

    raise ValueError(
        "No private key configured. Set SNOWFLAKE_PRIVATE_KEY (base64 DER) "
        "or SNOWFLAKE_PRIVATE_KEY_PATH (PEM file path)."
    )


def get_connection() -> snowflake.connector.SnowflakeConnection:
    """Create a Snowflake connection using key-pair auth."""
    return snowflake.connector.connect(
        account=SNOWFLAKE_ACCOUNT,
        user=SNOWFLAKE_USER,
        private_key=_load_private_key(),
        database=SNOWFLAKE_DATABASE,
        schema=SNOWFLAKE_SCHEMA,
        warehouse=SNOWFLAKE_WAREHOUSE,
        role=SNOWFLAKE_ROLE,
    )


def write_batch(conn: snowflake.connector.SnowflakeConnection, rows: list[dict]) -> int:
    """Write a batch of event rows to AUTH_EVENTS_RAW using write_pandas."""
    if not rows:
        return 0

    df = pd.DataFrame(rows, columns=COLUMNS)
    success, num_chunks, num_rows, _ = write_pandas(
        conn, df, TABLE_NAME, database=SNOWFLAKE_DATABASE, schema=SNOWFLAKE_SCHEMA
    )
    if success:
        logger.info("Wrote %d rows in %d chunks", num_rows, num_chunks)
    else:
        logger.error("write_pandas failed for batch of %d rows", len(rows))
    return num_rows
