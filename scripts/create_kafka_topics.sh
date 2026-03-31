#!/usr/bin/env bash
# create_kafka_topics.sh — Idempotent Kafka topic creation from kafka/topic-config.json
#
# Usage:
#   ./scripts/create_kafka_topics.sh [--bootstrap-server HOST:PORT] [--dry-run]
#
# Environment variables (override defaults):
#   KAFKA_BOOTSTRAP_SERVERS   Kafka broker address (default: localhost:9092)
#   KAFKA_TOPICS_CONFIG       Path to topic config JSON (default: kafka/topic-config.json)
#
# Examples:
#   ./scripts/create_kafka_topics.sh
#   KAFKA_BOOTSTRAP_SERVERS=broker1:9092 ./scripts/create_kafka_topics.sh
#   ./scripts/create_kafka_topics.sh --dry-run

set -euo pipefail

# --- Configuration ---
BOOTSTRAP_SERVER="${KAFKA_BOOTSTRAP_SERVERS:-localhost:9092}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${KAFKA_TOPICS_CONFIG:-${PROJECT_ROOT}/kafka/topic-config.json}"
DRY_RUN=false

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bootstrap-server) BOOTSTRAP_SERVER="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# --- Dependency checks ---
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required. Install with: brew install jq" >&2
  exit 1
fi
if ! command -v kafka-topics &>/dev/null && ! command -v kafka-topics.sh &>/dev/null; then
  echo "Error: kafka-topics CLI not found in PATH." >&2
  echo "Install Confluent CLI or add Kafka bin/ to PATH." >&2
  exit 1
fi
KAFKA_TOPICS_CMD="$(command -v kafka-topics 2>/dev/null || command -v kafka-topics.sh)"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

# --- Topic creation ---
echo "=== Kafka Topic Setup ==="
echo "Bootstrap server : $BOOTSTRAP_SERVER"
echo "Config file      : $CONFIG_FILE"
[[ "$DRY_RUN" == "true" ]] && echo "Mode             : DRY RUN (no topics will be created)"
echo ""

TOPIC_COUNT=$(jq '.topics | length' "$CONFIG_FILE")

for i in $(seq 0 $((TOPIC_COUNT - 1))); do
  TOPIC_NAME=$(jq -r ".topics[$i].name" "$CONFIG_FILE")
  PARTITIONS=$(jq -r ".topics[$i].partitions" "$CONFIG_FILE")
  REPLICATION_FACTOR=$(jq -r ".topics[$i].replication_factor" "$CONFIG_FILE")

  # Build --config flags from the config object
  CONFIG_FLAGS=""
  while IFS="=" read -r key value; do
    CONFIG_FLAGS="$CONFIG_FLAGS --config ${key}=${value}"
  done < <(jq -r ".topics[$i].config | to_entries[] | \"\(.key)=\(.value)\"" "$CONFIG_FILE")

  # Check if topic already exists
  if "$KAFKA_TOPICS_CMD" --bootstrap-server "$BOOTSTRAP_SERVER" --list 2>/dev/null | grep -q "^${TOPIC_NAME}$"; then
    echo "✓ Topic '${TOPIC_NAME}' already exists — skipping"
    continue
  fi

  echo "Creating topic '${TOPIC_NAME}'..."
  echo "  Partitions        : $PARTITIONS"
  echo "  Replication factor: $REPLICATION_FACTOR"
  echo "  Config            : $(jq -r ".topics[$i].config | to_entries[] | \"    \(.key)=\(.value)\"" "$CONFIG_FILE" | tr '\n' ' ')"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY RUN] Would run: $KAFKA_TOPICS_CMD --bootstrap-server $BOOTSTRAP_SERVER --create --topic $TOPIC_NAME --partitions $PARTITIONS --replication-factor $REPLICATION_FACTOR $CONFIG_FLAGS"
  else
    # shellcheck disable=SC2086
    "$KAFKA_TOPICS_CMD" \
      --bootstrap-server "$BOOTSTRAP_SERVER" \
      --create \
      --topic "$TOPIC_NAME" \
      --partitions "$PARTITIONS" \
      --replication-factor "$REPLICATION_FACTOR" \
      $CONFIG_FLAGS
    echo "✓ Created topic '${TOPIC_NAME}'"
  fi
done

echo ""
echo "=== Done ==="
