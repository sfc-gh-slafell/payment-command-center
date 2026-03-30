#!/usr/bin/env bash
# tests/validate_fallback_ingest.sh
# TDD validation for fallback ingest relay
#
# Issue #10: Fallback ingest relay (Python batch)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
FB_DIR="$PROJECT_DIR/fallback_ingest"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "=== Fallback Ingest Relay Validation Tests ==="
echo ""

# --- Test 1: pyproject.toml ---
echo "[1] fallback_ingest/pyproject.toml"

if [ -f "$FB_DIR/pyproject.toml" ]; then
  pass "pyproject.toml exists"
  for dep in confluent-kafka snowflake-connector-python pandas; do
    if grep -qi "$dep" "$FB_DIR/pyproject.toml"; then
      pass "Dependency $dep listed"
    else
      fail "Dependency $dep missing"
    fi
  done
else
  fail "pyproject.toml does not exist"
  for dep in confluent-kafka snowflake-connector-python pandas; do
    fail "Dependency $dep missing (file not found)"
  done
fi

# --- Test 2: config.py ---
echo "[2] fallback_ingest/config.py"

if [ -f "$FB_DIR/config.py" ]; then
  pass "config.py exists"
  for item in batch_size batch_timeout snowflake kafka; do
    if grep -qi "$item" "$FB_DIR/config.py"; then
      pass "Config field $item present"
    else
      fail "Config field $item missing"
    fi
  done
else
  fail "config.py does not exist"
  for item in batch_size batch_timeout snowflake kafka; do
    fail "Config field $item missing (file not found)"
  done
fi

# --- Test 3: sf_client.py ---
echo "[3] fallback_ingest/sf_client.py"

if [ -f "$FB_DIR/sf_client.py" ]; then
  pass "sf_client.py exists"

  if grep -qi 'key.*pair\|private_key\|key_pair' "$FB_DIR/sf_client.py"; then
    pass "Key-pair auth present"
  else
    fail "Key-pair auth missing"
  fi

  if grep -qi 'write_pandas\|write_dataframe\|COPY INTO' "$FB_DIR/sf_client.py"; then
    pass "Batch write method present"
  else
    fail "Batch write method missing"
  fi

  if grep -qi 'AUTH_EVENTS_RAW' "$FB_DIR/sf_client.py"; then
    pass "Target table AUTH_EVENTS_RAW present"
  else
    fail "Target table AUTH_EVENTS_RAW missing"
  fi

  if grep -qi 'source_topic\|source_partition\|source_offset' "$FB_DIR/sf_client.py"; then
    pass "Kafka metadata columns preserved"
  else
    fail "Kafka metadata columns not preserved"
  fi
else
  fail "sf_client.py does not exist"
  fail "Key-pair auth missing (file not found)"
  fail "Batch write method missing (file not found)"
  fail "Target table AUTH_EVENTS_RAW missing (file not found)"
  fail "Kafka metadata columns not preserved (file not found)"
fi

# --- Test 4: relay.py ---
echo "[4] fallback_ingest/relay.py"

if [ -f "$FB_DIR/relay.py" ]; then
  pass "relay.py exists"

  if grep -qi 'Consumer\|consumer' "$FB_DIR/relay.py"; then
    pass "Kafka consumer present"
  else
    fail "Kafka consumer missing"
  fi

  if grep -qi 'batch\|accumulate\|buffer' "$FB_DIR/relay.py"; then
    pass "Batch accumulation logic present"
  else
    fail "Batch accumulation logic missing"
  fi

  if grep -qi 'flush\|write' "$FB_DIR/relay.py"; then
    pass "Flush/write logic present"
  else
    fail "Flush/write logic missing"
  fi

  if grep -qi 'commit' "$FB_DIR/relay.py"; then
    pass "Offset commit present"
  else
    fail "Offset commit missing"
  fi
else
  fail "relay.py does not exist"
  fail "Kafka consumer missing (file not found)"
  fail "Batch accumulation logic missing (file not found)"
  fail "Flush/write logic missing (file not found)"
  fail "Offset commit missing (file not found)"
fi

# --- Test 5: Dockerfile ---
echo "[5] fallback_ingest/Dockerfile"

if [ -f "$FB_DIR/Dockerfile" ]; then
  pass "Dockerfile exists"

  if grep -qi 'python' "$FB_DIR/Dockerfile"; then
    pass "Python base image"
  else
    fail "Python base image missing"
  fi
else
  fail "Dockerfile does not exist"
  fail "Python base image missing (file not found)"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
