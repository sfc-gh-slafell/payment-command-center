#!/usr/bin/env bash
# tests/validate_schemachange.sh
# TDD validation script for schemachange migrations
#
# Issue #3: raw landing table DDL and grants
#
# Usage: ./tests/validate_schemachange.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
SC_DIR="$PROJECT_DIR/schemachange"
MIGRATIONS_DIR="$SC_DIR/migrations"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "=== Schemachange Validation Tests ==="
echo ""

# --- Test 1: schemachange config exists ---
echo "[1] Schemachange config"

if [ -f "$SC_DIR/schemachange-config.yml" ]; then
  pass "schemachange-config.yml exists"

  if grep -q 'PAYMENTS_DB' "$SC_DIR/schemachange-config.yml"; then
    pass "Database PAYMENTS_DB referenced in config"
  else
    fail "Database PAYMENTS_DB not found in config"
  fi

  if grep -q 'RAW' "$SC_DIR/schemachange-config.yml"; then
    pass "Schema RAW referenced in config"
  else
    fail "Schema RAW not found in config"
  fi
else
  fail "schemachange-config.yml does not exist"
  fail "Database PAYMENTS_DB not found in config"
  fail "Schema RAW not found in config"
fi

# --- Test 2: V1.0.0 migration — raw landing table ---
echo "[2] V1.0.0 migration — raw landing table"

V100="$MIGRATIONS_DIR/V1.0.0__create_raw_landing_table.sql"

if [ -f "$V100" ]; then
  pass "V1.0.0__create_raw_landing_table.sql exists"

  # Table name
  if grep -qi 'AUTH_EVENTS_RAW' "$V100"; then
    pass "Table AUTH_EVENTS_RAW referenced"
  else
    fail "Table AUTH_EVENTS_RAW not found"
  fi

  # Core business columns
  REQUIRED_COLUMNS=(
    "env"
    "event_ts"
    "event_id"
    "payment_id"
    "merchant_id"
    "merchant_name"
    "region"
    "country"
    "card_brand"
    "issuer_bin"
    "payment_method"
    "amount"
    "currency"
    "auth_status"
    "decline_code"
    "auth_latency_ms"
  )

  for col in "${REQUIRED_COLUMNS[@]}"; do
    if grep -qi "$col" "$V100"; then
      pass "Column $col present"
    else
      fail "Column $col missing"
    fi
  done

  # Kafka metadata columns
  KAFKA_COLUMNS=(
    "source_topic"
    "source_partition"
    "source_offset"
  )

  for col in "${KAFKA_COLUMNS[@]}"; do
    if grep -qi "$col" "$V100"; then
      pass "Kafka column $col present"
    else
      fail "Kafka column $col missing"
    fi
  done

  # Variant columns
  if grep -qi 'headers.*VARIANT' "$V100"; then
    pass "headers VARIANT column present"
  else
    fail "headers VARIANT column missing"
  fi

  if grep -qi 'payload.*VARIANT' "$V100"; then
    pass "payload VARIANT column present"
  else
    fail "payload VARIANT column missing"
  fi

  # ingested_at with DEFAULT
  if grep -qi 'ingested_at' "$V100"; then
    pass "ingested_at column present"
  else
    fail "ingested_at column missing"
  fi

  if grep -qi 'DEFAULT.*CURRENT_TIMESTAMP' "$V100"; then
    pass "DEFAULT CURRENT_TIMESTAMP present"
  else
    fail "DEFAULT CURRENT_TIMESTAMP missing"
  fi

  # Table properties
  if grep -qi 'ENABLE_SCHEMA_EVOLUTION.*FALSE' "$V100"; then
    pass "ENABLE_SCHEMA_EVOLUTION = FALSE present"
  else
    fail "ENABLE_SCHEMA_EVOLUTION = FALSE missing"
  fi

  if grep -qi 'DATA_RETENTION_TIME_IN_DAYS.*14' "$V100"; then
    pass "DATA_RETENTION_TIME_IN_DAYS = 14 present"
  else
    fail "DATA_RETENTION_TIME_IN_DAYS = 14 missing"
  fi

  # Column types
  if grep -qi 'TIMESTAMP_NTZ' "$V100"; then
    pass "TIMESTAMP_NTZ type used"
  else
    fail "TIMESTAMP_NTZ type not found"
  fi

  if grep -qi 'NUMBER(12,2)' "$V100"; then
    pass "NUMBER(12,2) type used for amount"
  else
    fail "NUMBER(12,2) type not found for amount"
  fi
else
  fail "V1.0.0__create_raw_landing_table.sql does not exist"
  # Bulk fail all column checks
  for col in env event_ts event_id payment_id merchant_id merchant_name region country card_brand issuer_bin payment_method amount currency auth_status decline_code auth_latency_ms source_topic source_partition source_offset; do
    fail "Column $col missing (file not found)"
  done
  fail "headers VARIANT column missing"
  fail "payload VARIANT column missing"
  fail "ingested_at column missing"
  fail "DEFAULT CURRENT_TIMESTAMP missing"
  fail "ENABLE_SCHEMA_EVOLUTION = FALSE missing"
  fail "DATA_RETENTION_TIME_IN_DAYS = 14 missing"
  fail "TIMESTAMP_NTZ type not found"
  fail "NUMBER(12,2) type not found for amount"
fi

# --- Test 3: V1.1.0 migration — grants ---
echo "[3] V1.1.0 migration — grants"

V110="$MIGRATIONS_DIR/V1.1.0__grant_raw_table_privileges.sql"

if [ -f "$V110" ]; then
  pass "V1.1.0__grant_raw_table_privileges.sql exists"

  # INSERT grant for INGEST role
  if grep -qi 'GRANT.*INSERT.*PAYMENTS_INGEST_ROLE\|PAYMENTS_INGEST_ROLE.*INSERT' "$V110"; then
    pass "GRANT INSERT to PAYMENTS_INGEST_ROLE present"
  else
    fail "GRANT INSERT to PAYMENTS_INGEST_ROLE missing"
  fi

  # SELECT grant for APP role
  if grep -qi 'GRANT.*SELECT.*PAYMENTS_APP_ROLE\|PAYMENTS_APP_ROLE.*SELECT' "$V110"; then
    pass "GRANT SELECT to PAYMENTS_APP_ROLE present"
  else
    fail "GRANT SELECT to PAYMENTS_APP_ROLE missing"
  fi

  # SELECT grant for OPS role
  if grep -qi 'GRANT.*SELECT.*PAYMENTS_OPS_ROLE\|PAYMENTS_OPS_ROLE.*SELECT' "$V110"; then
    pass "GRANT SELECT to PAYMENTS_OPS_ROLE present"
  else
    fail "GRANT SELECT to PAYMENTS_OPS_ROLE missing"
  fi

  # References AUTH_EVENTS_RAW
  if grep -qi 'AUTH_EVENTS_RAW' "$V110"; then
    pass "AUTH_EVENTS_RAW referenced in grants"
  else
    fail "AUTH_EVENTS_RAW not referenced in grants"
  fi
else
  fail "V1.1.0__grant_raw_table_privileges.sql does not exist"
  fail "GRANT INSERT to PAYMENTS_INGEST_ROLE missing"
  fail "GRANT SELECT to PAYMENTS_APP_ROLE missing"
  fail "GRANT SELECT to PAYMENTS_OPS_ROLE missing"
  fail "AUTH_EVENTS_RAW not referenced in grants"
fi

# --- Test 4: SQL syntax validation ---
echo "[4] SQL syntax validation"

# Basic SQL syntax checks (no live connection needed)
if [ -f "$V100" ]; then
  if grep -qi 'CREATE.*TABLE' "$V100"; then
    pass "CREATE TABLE statement found in V1.0.0"
  else
    fail "CREATE TABLE statement missing from V1.0.0"
  fi
fi

if [ -f "$V110" ]; then
  if grep -qi 'GRANT' "$V110"; then
    pass "GRANT statement found in V1.1.0"
  else
    fail "GRANT statement missing from V1.1.0"
  fi
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
