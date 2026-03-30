#!/usr/bin/env bash
# tests/validate_kafka.sh
# TDD validation script for Kafka topic and connector configuration
#
# Issue #6: Kafka topic creation and configuration
# Issue #7: Kafka Connect HP connector config and deployment
#
# Usage: ./tests/validate_kafka.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
KAFKA_DIR="$PROJECT_DIR/kafka-connect"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "=== Kafka Configuration Validation Tests ==="
echo ""

# =============================================================================
# Issue #6: Kafka topic creation and configuration
# =============================================================================

echo "--- Issue #6: Kafka Topic Configuration ---"
echo ""

# --- Test 1: README exists with topic creation docs ---
echo "[1] kafka-connect/README.md"

README="$KAFKA_DIR/README.md"

if [ -f "$README" ]; then
  pass "README.md exists"

  # Topic name
  if grep -q 'payments.auth' "$README"; then
    pass "Topic payments.auth documented"
  else
    fail "Topic payments.auth not documented"
  fi

  # 24 partitions
  if grep -q '24' "$README"; then
    pass "24 partitions documented"
  else
    fail "24 partitions not documented"
  fi

  # 72-hour retention
  if grep -q '72' "$README" || grep -q '259200000' "$README"; then
    pass "72-hour retention documented"
  else
    fail "72-hour retention not documented"
  fi

  # Self-managed Kafka creation command
  if grep -qi 'kafka-topics.*--create\|kafka-topics\.sh' "$README"; then
    pass "Self-managed Kafka creation command present"
  else
    fail "Self-managed Kafka creation command missing"
  fi

  # Confluent Cloud documentation
  if grep -qi 'confluent\|ccloud\|confluent cloud' "$README"; then
    pass "Confluent Cloud documentation present"
  else
    fail "Confluent Cloud documentation missing"
  fi

  # Partitioning strategy
  if grep -qi 'merchant_id.*key\|key.*merchant_id\|partition.*merchant' "$README"; then
    pass "Partitioning strategy (merchant_id key) documented"
  else
    fail "Partitioning strategy (merchant_id key) not documented"
  fi

  # Consumer group
  if grep -q 'snowflake-hp-sink-payments' "$README"; then
    pass "Consumer group documented"
  else
    fail "Consumer group not documented"
  fi

  # Throughput design
  if grep -q '500' "$README" && grep -q '2000' "$README"; then
    pass "Throughput design documented (500-2000 events/sec)"
  else
    fail "Throughput design not documented"
  fi
else
  fail "README.md does not exist"
  for item in "Topic payments.auth" "24 partitions" "72-hour retention" "Self-managed Kafka creation command" "Confluent Cloud documentation" "Partitioning strategy" "Consumer group" "Throughput design"; do
    fail "$item not documented (file not found)"
  done
fi

# --- Test 1b: Topic actually exists on broker ---
echo "[1b] Live topic verification"

if docker exec payments-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic payments.auth > /tmp/topic_describe.txt 2>/dev/null; then
  pass "Topic payments.auth exists on broker"

  if grep -q 'PartitionCount: *24\|PartitionCount:24' /tmp/topic_describe.txt || grep -c 'Partition:' /tmp/topic_describe.txt | grep -q '24'; then
    pass "Topic has 24 partitions"
  else
    fail "Topic does not have 24 partitions"
  fi

  if grep -q 'retention.ms=259200000' /tmp/topic_describe.txt; then
    pass "retention.ms=259200000 (72 hours) configured"
  else
    fail "retention.ms=259200000 not configured"
  fi

  if grep -q 'cleanup.policy=delete' /tmp/topic_describe.txt; then
    pass "cleanup.policy=delete configured"
  else
    fail "cleanup.policy=delete not configured"
  fi

  rm -f /tmp/topic_describe.txt
else
  fail "Topic payments.auth does not exist on broker (is Kafka running?)"
  fail "Topic does not have 24 partitions (broker unreachable)"
  fail "retention.ms=259200000 not configured (broker unreachable)"
  fail "cleanup.policy=delete not configured (broker unreachable)"
fi

# --- Test 1c: docker-compose.yml exists ---
echo "[1c] docker-compose.yml"

if [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
  pass "docker-compose.yml exists"

  if grep -q 'apache/kafka' "$PROJECT_DIR/docker-compose.yml"; then
    pass "Uses apache/kafka image"
  else
    fail "Does not use apache/kafka image"
  fi
else
  fail "docker-compose.yml does not exist"
  fail "Does not use apache/kafka image (file not found)"
fi

# =============================================================================
# Issue #7: Kafka Connect HP connector config
# =============================================================================

echo ""
echo "--- Issue #7: HP Connector Configuration ---"
echo ""

# --- Test 2: shared.json exists with required config ---
echo "[2] kafka-connect/shared.json"

SHARED_JSON="$KAFKA_DIR/shared.json"

if [ -f "$SHARED_JSON" ]; then
  pass "shared.json exists"

  # Connector class (v4.x)
  if grep -q 'SnowflakeStreamingSinkConnector' "$SHARED_JSON"; then
    pass "v4.x connector class present"
  else
    fail "v4.x connector class missing"
  fi

  # tasks.max=24
  if grep -q '"tasks.max"' "$SHARED_JSON" && grep -q '24' "$SHARED_JSON"; then
    pass "tasks.max=24 present"
  else
    fail "tasks.max=24 missing"
  fi

  # topics
  if grep -q '"topics"' "$SHARED_JSON" && grep -q 'payments.auth' "$SHARED_JSON"; then
    pass "topics=payments.auth present"
  else
    fail "topics=payments.auth missing"
  fi

  # topic2table.map
  if grep -q 'topic2table.map' "$SHARED_JSON" && grep -q 'AUTH_EVENTS_RAW' "$SHARED_JSON"; then
    pass "topic2table.map to AUTH_EVENTS_RAW present"
  else
    fail "topic2table.map to AUTH_EVENTS_RAW missing"
  fi

  # metadata.topic=true
  if grep -q 'metadata.topic' "$SHARED_JSON"; then
    pass "metadata.topic config present"
  else
    fail "metadata.topic config missing"
  fi

  # metadata.offsetAndPartition=true
  if grep -q 'metadata.offsetAndPartition' "$SHARED_JSON"; then
    pass "metadata.offsetAndPartition config present"
  else
    fail "metadata.offsetAndPartition config missing"
  fi

  # JsonConverter
  if grep -q 'JsonConverter' "$SHARED_JSON"; then
    pass "JsonConverter configured"
  else
    fail "JsonConverter not configured"
  fi

  # NO snowflake.warehouse.name (HP is serverless)
  if grep -q 'snowflake.warehouse.name' "$SHARED_JSON"; then
    fail "snowflake.warehouse.name should NOT be present (HP is serverless)"
  else
    pass "No snowflake.warehouse.name (correct for HP)"
  fi

  # NO snowflake.ingestion.method (v4.x only supports streaming)
  if grep -q 'snowflake.ingestion.method' "$SHARED_JSON"; then
    fail "snowflake.ingestion.method should NOT be present (v4.x only)"
  else
    pass "No snowflake.ingestion.method (correct for v4.x)"
  fi

  # Private key externalized (ConfigProvider reference or placeholder)
  if grep -qi 'ConfigProvider\|SNOWFLAKE_PRIVATE_KEY\|\${file\|\${env' "$SHARED_JSON"; then
    pass "Private key externalized via ConfigProvider or env"
  else
    fail "Private key not externalized"
  fi
else
  fail "shared.json does not exist"
  for item in "v4.x connector class" "tasks.max=24" "topics=payments.auth" "topic2table.map" "metadata.topic" "metadata.offsetAndPartition" "JsonConverter" "No snowflake.warehouse.name" "No snowflake.ingestion.method" "Private key externalized"; do
    fail "$item (file not found)"
  done
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
