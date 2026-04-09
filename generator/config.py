"""Environment configuration for the event generator."""

import os


BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
TOPIC = os.getenv("KAFKA_TOPIC", "payments.auth")
DEFAULT_RATE = int(os.getenv("GENERATOR_RATE", "500"))
DEFAULT_ENV = os.getenv("GENERATOR_ENV", "dev")
