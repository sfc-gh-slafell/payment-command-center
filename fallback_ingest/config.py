"""Configuration for the fallback ingest relay."""

import os

# Kafka consumer config
KAFKA_BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
KAFKA_TOPIC = os.getenv("KAFKA_TOPIC", "payments.auth")
KAFKA_GROUP_ID = os.getenv("KAFKA_GROUP_ID", "snowflake-fallback-relay")

# Batch settings
BATCH_SIZE = int(os.getenv("BATCH_SIZE", "1000"))
BATCH_TIMEOUT = float(os.getenv("BATCH_TIMEOUT", "5.0"))

# Snowflake connection
SNOWFLAKE_ACCOUNT = os.getenv("SNOWFLAKE_ACCOUNT", "")
SNOWFLAKE_USER = os.getenv("SNOWFLAKE_USER", "")
# Accept the key either as a base64-encoded DER string (SNOWFLAKE_PRIVATE_KEY,
# matching the V4 Kafka connector's .env format) or as a PEM file path
# (SNOWFLAKE_PRIVATE_KEY_PATH, for local dev outside Docker).
SNOWFLAKE_PRIVATE_KEY = os.getenv("SNOWFLAKE_PRIVATE_KEY", "")
SNOWFLAKE_PRIVATE_KEY_PATH = os.getenv("SNOWFLAKE_PRIVATE_KEY_PATH", "")
SNOWFLAKE_DATABASE = os.getenv("SNOWFLAKE_DATABASE", "PAYMENTS_DB")
SNOWFLAKE_SCHEMA = os.getenv("SNOWFLAKE_SCHEMA", "RAW")
SNOWFLAKE_WAREHOUSE = os.getenv("SNOWFLAKE_WAREHOUSE", "PAYMENTS_ADMIN_WH")
SNOWFLAKE_ROLE = os.getenv("SNOWFLAKE_ROLE", "PAYMENTS_INGEST_ROLE")
