#!/usr/bin/env bash
# tests/validate_generator.sh
# TDD validation script for event generator
#
# Issue #8: Event generator scaffold and Kafka producer
# Issue #9: Scenario profiles and control API
#
# Usage: ./tests/validate_generator.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
GEN_DIR="$PROJECT_DIR/generator"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "=== Event Generator Validation Tests ==="
echo ""

# =============================================================================
# Issue #8: Project scaffold and Kafka producer
# =============================================================================

echo "--- Issue #8: Generator Scaffold ---"
echo ""

# --- Test 1: requirements.txt ---
echo "[1] generator/requirements.txt"

if [ -f "$GEN_DIR/requirements.txt" ]; then
  pass "requirements.txt exists"

  for dep in confluent-kafka faker fastapi uvicorn; do
    if grep -qi "$dep" "$GEN_DIR/requirements.txt"; then
      pass "Dependency $dep listed"
    else
      fail "Dependency $dep missing"
    fi
  done
else
  fail "requirements.txt does not exist"
  for dep in confluent-kafka faker fastapi uvicorn; do
    fail "Dependency $dep missing (file not found)"
  done
fi

# --- Test 2: config.py ---
echo "[2] generator/config.py"

if [ -f "$GEN_DIR/config.py" ]; then
  pass "config.py exists"

  for item in bootstrap_server topic rate env; do
    if grep -qi "$item" "$GEN_DIR/config.py"; then
      pass "Config field $item present"
    else
      fail "Config field $item missing"
    fi
  done
else
  fail "config.py does not exist"
  for item in bootstrap_server topic rate env; do
    fail "Config field $item missing (file not found)"
  done
fi

# --- Test 3: catalog.py ---
echo "[3] generator/catalog.py"

if [ -f "$GEN_DIR/catalog.py" ]; then
  pass "catalog.py exists"

  # Merchant catalog
  if grep -qi 'merchant' "$GEN_DIR/catalog.py"; then
    pass "Merchant catalog present"
  else
    fail "Merchant catalog missing"
  fi

  # BIN catalog
  if grep -qi '411111\|555555\|BIN\|bin' "$GEN_DIR/catalog.py"; then
    pass "BIN catalog present"
  else
    fail "BIN catalog missing"
  fi

  # Region/country map
  if grep -qi 'NA\|EU\|APAC\|LATAM' "$GEN_DIR/catalog.py"; then
    pass "Region map present"
  else
    fail "Region map missing"
  fi

  # Card brands
  if grep -qi 'VISA\|MASTERCARD\|AMEX' "$GEN_DIR/catalog.py"; then
    pass "Card brands present"
  else
    fail "Card brands missing"
  fi

  # Payment methods
  if grep -qi 'CREDIT\|DEBIT\|PREPAID' "$GEN_DIR/catalog.py"; then
    pass "Payment methods present"
  else
    fail "Payment methods missing"
  fi
else
  fail "catalog.py does not exist"
  for item in "Merchant catalog" "BIN catalog" "Region map" "Card brands" "Payment methods"; do
    fail "$item missing (file not found)"
  done
fi

# --- Test 4: producer.py ---
echo "[4] generator/producer.py"

if [ -f "$GEN_DIR/producer.py" ]; then
  pass "producer.py exists"

  # Kafka producer config
  if grep -qi 'zstd\|compression' "$GEN_DIR/producer.py"; then
    pass "zstd compression configured"
  else
    fail "zstd compression not configured"
  fi

  if grep -qi 'acks.*all\|acks.*-1' "$GEN_DIR/producer.py"; then
    pass "acks=all configured"
  else
    fail "acks=all not configured"
  fi

  # generate_event function
  if grep -qi 'generate_event\|def.*event' "$GEN_DIR/producer.py"; then
    pass "generate_event function present"
  else
    fail "generate_event function missing"
  fi

  # merchant_id as key
  if grep -qi 'merchant_id.*key\|key.*merchant_id' "$GEN_DIR/producer.py"; then
    pass "merchant_id used as Kafka key"
  else
    fail "merchant_id not used as Kafka key"
  fi

  # Event schema fields
  EVENT_FIELDS=(event_ts event_id payment_id merchant_id auth_status decline_code auth_latency_ms amount currency)
  for field in "${EVENT_FIELDS[@]}"; do
    if grep -q "$field" "$GEN_DIR/producer.py"; then
      pass "Event field $field present"
    else
      fail "Event field $field missing"
    fi
  done
else
  fail "producer.py does not exist"
  fail "zstd compression not configured (file not found)"
  fail "acks=all not configured (file not found)"
  fail "generate_event function missing (file not found)"
  fail "merchant_id not used as Kafka key (file not found)"
  for field in event_ts event_id payment_id merchant_id auth_status decline_code auth_latency_ms amount currency; do
    fail "Event field $field missing (file not found)"
  done
fi

# =============================================================================
# Issue #9: Scenario profiles and control API
# =============================================================================

echo ""
echo "--- Issue #9: Scenarios and Control API ---"
echo ""

# --- Test 5: scenarios.py ---
echo "[5] generator/scenarios.py"

if [ -f "$GEN_DIR/scenarios.py" ]; then
  pass "scenarios.py exists"

  for scenario in baseline issuer_outage merchant_decline_spike latency_spike; do
    if grep -qi "$scenario" "$GEN_DIR/scenarios.py"; then
      pass "Scenario $scenario defined"
    else
      fail "Scenario $scenario missing"
    fi
  done

  if grep -qi 'modify_event\|modify' "$GEN_DIR/scenarios.py"; then
    pass "modify_event interface present"
  else
    fail "modify_event interface missing"
  fi

  if grep -qi 'seed\|deterministic' "$GEN_DIR/scenarios.py"; then
    pass "Deterministic seed support present"
  else
    fail "Deterministic seed support missing"
  fi
else
  fail "scenarios.py does not exist"
  for scenario in baseline issuer_outage merchant_decline_spike latency_spike; do
    fail "Scenario $scenario missing (file not found)"
  done
  fail "modify_event interface missing (file not found)"
  fail "Deterministic seed support missing (file not found)"
fi

# --- Test 6: main.py (FastAPI control API) ---
echo "[6] generator/main.py"

if [ -f "$GEN_DIR/main.py" ]; then
  pass "main.py exists"

  if grep -qi 'FastAPI\|fastapi' "$GEN_DIR/main.py"; then
    pass "FastAPI app present"
  else
    fail "FastAPI app missing"
  fi

  for endpoint in '/status' '/scenario' '/rate'; do
    if grep -q "$endpoint" "$GEN_DIR/main.py"; then
      pass "Endpoint $endpoint present"
    else
      fail "Endpoint $endpoint missing"
    fi
  done

  if grep -qi 'duration' "$GEN_DIR/main.py"; then
    pass "Duration-based auto-return present"
  else
    fail "Duration-based auto-return missing"
  fi
else
  fail "main.py does not exist"
  fail "FastAPI app missing (file not found)"
  for endpoint in '/status' '/scenario' '/rate'; do
    fail "Endpoint $endpoint missing (file not found)"
  done
  fail "Duration-based auto-return missing (file not found)"
fi

# --- Test 7: Dockerfile ---
echo "[7] generator/Dockerfile"

if [ -f "$GEN_DIR/Dockerfile" ]; then
  pass "Dockerfile exists"

  if grep -qi 'python.*3.11\|python:3.11' "$GEN_DIR/Dockerfile"; then
    pass "Python 3.11 base image"
  else
    fail "Python 3.11 base image missing"
  fi

  if grep -qi 'uvicorn' "$GEN_DIR/Dockerfile"; then
    pass "uvicorn CMD present"
  else
    fail "uvicorn CMD missing"
  fi
else
  fail "Dockerfile does not exist"
  fail "Python 3.11 base image missing (file not found)"
  fail "uvicorn CMD missing (file not found)"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
