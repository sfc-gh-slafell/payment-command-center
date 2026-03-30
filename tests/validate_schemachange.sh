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

# =============================================================================
# Issue #4: Interactive tables and warehouse association
# =============================================================================

echo ""
echo "--- Issue #4: Interactive Tables ---"
echo ""

# --- Test 5: V1.2.0 migration — interactive tables ---
echo "[5] V1.2.0 migration — interactive tables"

V120="$MIGRATIONS_DIR/V1.2.0__create_interactive_tables.sql"

if [ -f "$V120" ]; then
  pass "V1.2.0__create_interactive_tables.sql exists"

  # IT_AUTH_MINUTE_METRICS
  if grep -qi 'IT_AUTH_MINUTE_METRICS' "$V120"; then
    pass "IT_AUTH_MINUTE_METRICS referenced"
  else
    fail "IT_AUTH_MINUTE_METRICS not found"
  fi

  if grep -qi 'CREATE.*INTERACTIVE TABLE' "$V120"; then
    pass "CREATE INTERACTIVE TABLE statement present"
  else
    fail "CREATE INTERACTIVE TABLE statement missing"
  fi

  # IT_AUTH_MINUTE_METRICS columns (22 columns)
  METRICS_COLUMNS=(
    "event_minute"
    "env"
    "merchant_id"
    "merchant_name"
    "region"
    "country"
    "card_brand"
    "issuer_bin"
    "payment_method"
    "event_count"
    "decline_count"
    "approval_count"
    "error_count"
    "latency_sum_ms"
    "latency_count"
    "latency_0_50ms"
    "latency_50_100ms"
    "latency_100_200ms"
    "latency_200_500ms"
    "latency_500_1000ms"
    "latency_1000ms_plus"
    "total_amount"
    "avg_amount"
  )

  for col in "${METRICS_COLUMNS[@]}"; do
    if grep -qi "$col" "$V120"; then
      pass "Metrics column $col present"
    else
      fail "Metrics column $col missing"
    fi
  done

  # CLUSTER BY for metrics
  if grep -qi 'CLUSTER BY.*(event_minute.*env.*merchant_id.*region)' "$V120"; then
    pass "IT_AUTH_MINUTE_METRICS CLUSTER BY correct"
  else
    fail "IT_AUTH_MINUTE_METRICS CLUSTER BY incorrect or missing"
  fi

  # TARGET_LAG
  if grep -qi "TARGET_LAG.*=.*'60 seconds'" "$V120"; then
    pass "TARGET_LAG = '60 seconds' present"
  else
    fail "TARGET_LAG = '60 seconds' missing"
  fi

  # WAREHOUSE = PAYMENTS_REFRESH_WH
  if grep -qi 'WAREHOUSE.*=.*PAYMENTS_REFRESH_WH' "$V120"; then
    pass "WAREHOUSE = PAYMENTS_REFRESH_WH present"
  else
    fail "WAREHOUSE = PAYMENTS_REFRESH_WH missing"
  fi

  # Dedup CTE with QUALIFY ROW_NUMBER
  if grep -qi 'QUALIFY.*ROW_NUMBER' "$V120"; then
    pass "Dedup CTE with QUALIFY ROW_NUMBER present"
  else
    fail "Dedup CTE with QUALIFY ROW_NUMBER missing"
  fi

  # IT_AUTH_EVENT_SEARCH
  if grep -qi 'IT_AUTH_EVENT_SEARCH' "$V120"; then
    pass "IT_AUTH_EVENT_SEARCH referenced"
  else
    fail "IT_AUTH_EVENT_SEARCH not found"
  fi

  # IT_AUTH_EVENT_SEARCH columns (16 columns)
  SEARCH_COLUMNS=(
    "event_ts"
    "event_id"
    "payment_id"
    "amount"
    "currency"
    "auth_status"
    "decline_code"
    "auth_latency_ms"
  )

  for col in "${SEARCH_COLUMNS[@]}"; do
    if grep -qi "$col" "$V120"; then
      pass "Search column $col present"
    else
      fail "Search column $col missing"
    fi
  done

  # CLUSTER BY for event search
  if grep -qi 'CLUSTER BY.*(event_ts.*env.*merchant_id.*auth_status)' "$V120"; then
    pass "IT_AUTH_EVENT_SEARCH CLUSTER BY correct"
  else
    fail "IT_AUTH_EVENT_SEARCH CLUSTER BY incorrect or missing"
  fi

  # 60-minute window for event search
  if grep -qi "DATEADD.*MINUTE.*-60\|DATEADD.*'MINUTE'.*-60" "$V120"; then
    pass "60-minute window present in event search"
  else
    fail "60-minute window missing in event search"
  fi

  # GROUP BY ALL in metrics
  if grep -qi 'GROUP BY ALL' "$V120"; then
    pass "GROUP BY ALL present in metrics query"
  else
    fail "GROUP BY ALL missing in metrics query"
  fi
else
  fail "V1.2.0__create_interactive_tables.sql does not exist"
  fail "IT_AUTH_MINUTE_METRICS not found"
  fail "CREATE INTERACTIVE TABLE statement missing"
  for col in event_minute env merchant_id merchant_name region country card_brand issuer_bin payment_method event_count decline_count approval_count error_count latency_sum_ms latency_count latency_0_50ms latency_50_100ms latency_100_200ms latency_200_500ms latency_500_1000ms latency_1000ms_plus total_amount avg_amount; do
    fail "Metrics column $col missing (file not found)"
  done
  fail "IT_AUTH_MINUTE_METRICS CLUSTER BY incorrect or missing"
  fail "TARGET_LAG = '60 seconds' missing"
  fail "WAREHOUSE = PAYMENTS_REFRESH_WH missing"
  fail "Dedup CTE with QUALIFY ROW_NUMBER missing"
  fail "IT_AUTH_EVENT_SEARCH not found"
  for col in event_ts event_id payment_id amount currency auth_status decline_code auth_latency_ms; do
    fail "Search column $col missing (file not found)"
  done
  fail "IT_AUTH_EVENT_SEARCH CLUSTER BY incorrect or missing"
  fail "60-minute window missing in event search"
  fail "GROUP BY ALL missing in metrics query"
fi

# --- Test 6: V1.3.0 migration — warehouse association ---
echo "[6] V1.3.0 migration — warehouse association"

V130="$MIGRATIONS_DIR/V1.3.0__create_interactive_warehouse_table_assoc.sql"

if [ -f "$V130" ]; then
  pass "V1.3.0__create_interactive_warehouse_table_assoc.sql exists"

  if grep -qi 'ALTER WAREHOUSE.*PAYMENTS_INTERACTIVE_WH' "$V130"; then
    pass "ALTER WAREHOUSE PAYMENTS_INTERACTIVE_WH present"
  else
    fail "ALTER WAREHOUSE PAYMENTS_INTERACTIVE_WH missing"
  fi

  if grep -qi 'TABLES' "$V130"; then
    pass "TABLES clause present"
  else
    fail "TABLES clause missing"
  fi

  if grep -qi 'IT_AUTH_MINUTE_METRICS' "$V130"; then
    pass "IT_AUTH_MINUTE_METRICS in association"
  else
    fail "IT_AUTH_MINUTE_METRICS missing from association"
  fi

  if grep -qi 'IT_AUTH_EVENT_SEARCH' "$V130"; then
    pass "IT_AUTH_EVENT_SEARCH in association"
  else
    fail "IT_AUTH_EVENT_SEARCH missing from association"
  fi

  if grep -qi 'RESUME' "$V130"; then
    pass "RESUME statement present"
  else
    fail "RESUME statement missing"
  fi
else
  fail "V1.3.0__create_interactive_warehouse_table_assoc.sql does not exist"
  fail "ALTER WAREHOUSE PAYMENTS_INTERACTIVE_WH missing"
  fail "TABLES clause missing"
  fail "IT_AUTH_MINUTE_METRICS missing from association"
  fail "IT_AUTH_EVENT_SEARCH missing from association"
  fail "RESUME statement missing"
fi

# --- Test 7: V1.4.0 migration — serve grants ---
echo "[7] V1.4.0 migration — serve grants"

V140="$MIGRATIONS_DIR/V1.4.0__grant_serve_privileges.sql"

if [ -f "$V140" ]; then
  pass "V1.4.0__grant_serve_privileges.sql exists"

  if grep -qi 'GRANT.*SELECT.*PAYMENTS_APP_ROLE\|PAYMENTS_APP_ROLE.*SELECT' "$V140"; then
    pass "GRANT SELECT to PAYMENTS_APP_ROLE present"
  else
    fail "GRANT SELECT to PAYMENTS_APP_ROLE missing"
  fi

  if grep -qi 'SERVE' "$V140"; then
    pass "SERVE schema referenced"
  else
    fail "SERVE schema not referenced"
  fi
else
  fail "V1.4.0__grant_serve_privileges.sql does not exist"
  fail "GRANT SELECT to PAYMENTS_APP_ROLE missing"
  fail "SERVE schema not referenced"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
