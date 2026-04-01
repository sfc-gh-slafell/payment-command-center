"""Environment configuration for the event generator."""

import os


BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
TOPIC = os.getenv("KAFKA_TOPIC", "payments.auth")
V3_TOPIC = os.getenv("KAFKA_V3_TOPIC", "payments.auth.v3")
DEFAULT_RATE = int(os.getenv("GENERATOR_RATE", "500"))
DEFAULT_ENV = os.getenv("GENERATOR_ENV", "dev")
