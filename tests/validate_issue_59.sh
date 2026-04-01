#!/usr/bin/env bash
# tests/validate_issue_59.sh
# TDD validation script for Issue #59: Kafka V3 vs V4 HP connector benchmark
#
# Validates:
#   - payments.auth.v3 Kafka topic config
#   - V3 connector Dockerfile and config
#   - docker-compose V3 service
#   - Schemachange migrations for AUTH_EVENTS_RAW_V3
#   - Streamlit benchmark page
#   - Generator dual-topic publish
#
# Usage: ./tests/validate_issue_59.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "=== Issue #59: Kafka V3 vs V4 HP Benchmark Validation ==="
echo ""

# =============================================================================
# Section 1: Kafka topic config — payments.auth.v3
# =============================================================================

echo "--- [1] Kafka topic config: payments.auth.v3 ---"
echo ""

TOPIC_CONFIG="$PROJECT_DIR/kafka/topic-config.json"

if [ -f "$TOPIC_CONFIG" ]; then
  pass "kafka/topic-config.json exists"

  if grep -q 'payments.auth.v3' "$TOPIC_CONFIG"; then
    pass "payments.auth.v3 topic defined"
  else
    fail "payments.auth.v3 topic missing from topic-config.json"
  fi
else
  fail "kafka/topic-config.json does not exist"
  fail "payments.auth.v3 topic missing (file not found)"
fi

# =============================================================================
# Section 2: V3 connector Dockerfile
# =============================================================================

echo ""
echo "--- [2] kafka-connect-v3/Dockerfile ---"
echo ""

V3_DOCKERFILE="$PROJECT_DIR/kafka-connect-v3/Dockerfile"

if [ -f "$V3_DOCKERFILE" ]; then
  pass "kafka-connect-v3/Dockerfile exists"

  # Must use Confluent Hub (not Maven Central)
  if grep -q 'confluent-hub install' "$V3_DOCKERFILE"; then
    pass "Uses confluent-hub install (not Maven)"
  else
    fail "Does not use confluent-hub install"
  fi

  # Must install V3 connector (3.x)
  if grep -q 'snowflake-kafka-connector:3\.' "$V3_DOCKERFILE" || grep -q 'snowflakeinc/snowflake-kafka-connector:3' "$V3_DOCKERFILE"; then
    pass "Installs V3 connector (3.x series)"
  else
    fail "V3 connector (3.x) not referenced in Dockerfile"
  fi

  # Must NOT reference Maven Central for V4 JAR
  if grep -q 'SnowflakeStreamingSinkConnector\|4\.0\.0' "$V3_DOCKERFILE"; then
    fail "Dockerfile should not reference V4 HP connector"
  else
    pass "No V4 HP artifacts in V3 Dockerfile"
  fi
else
  fail "kafka-connect-v3/Dockerfile does not exist"
  fail "confluent-hub install not verified (file not found)"
  fail "V3 connector version not verified (file not found)"
  fail "V4 artifacts check skipped (file not found)"
fi

# =============================================================================
# Section 3: V3 connector config (shared.json)
# =============================================================================

echo ""
echo "--- [3] kafka-connect-v3/shared.json ---"
echo ""

V3_CONFIG="$PROJECT_DIR/kafka-connect-v3/shared.json"

if [ -f "$V3_CONFIG" ]; then
  pass "kafka-connect-v3/shared.json exists"

  # Must use V3 class (NOT StreamingSinkConnector)
  if grep -q 'SnowflakeSinkConnector' "$V3_CONFIG" && ! grep -q 'SnowflakeStreamingSinkConnector' "$V3_CONFIG"; then
    pass "V3 connector class (SnowflakeSinkConnector) present"
  else
    fail "V3 connector class missing (expected SnowflakeSinkConnector)"
  fi

  # Must NOT use V4 class
  if grep -q 'SnowflakeStreamingSinkConnector' "$V3_CONFIG"; then
    fail "V4 connector class should NOT be in V3 config"
  else
    pass "No V4 connector class in V3 config"
  fi

  # Must use SNOWPIPE_STREAMING ingestion method
  if grep -q 'SNOWPIPE_STREAMING' "$V3_CONFIG"; then
    pass "snowflake.ingestion.method=SNOWPIPE_STREAMING present"
  else
    fail "snowflake.ingestion.method=SNOWPIPE_STREAMING missing"
  fi

  # Must target payments.auth.v3
  if grep -q 'payments.auth.v3' "$V3_CONFIG"; then
    pass "Topic payments.auth.v3 referenced"
  else
    fail "Topic payments.auth.v3 not referenced"
  fi

  # Must map to AUTH_EVENTS_RAW_V3
  if grep -q 'AUTH_EVENTS_RAW_V3' "$V3_CONFIG"; then
    pass "Destination table AUTH_EVENTS_RAW_V3 referenced"
  else
    fail "Destination table AUTH_EVENTS_RAW_V3 missing"
  fi

  # Credentials must be externalized
  if grep -qi '\${env:SNOWFLAKE_PRIVATE_KEY\|SNOWFLAKE_PRIVATE_KEY}' "$V3_CONFIG"; then
    pass "Private key externalized via env var"
  else
    fail "Private key not externalized"
  fi

  # Must NOT have V4-only keys
  if grep -q '"snowflake.metadata.offset.and.partition"' "$V3_CONFIG"; then
    fail "V4-only key snowflake.metadata.offset.and.partition found in V3 config (use camelCase form)"
  else
    pass "No V4-only dot-separated metadata key (correct for V3)"
  fi
else
  fail "kafka-connect-v3/shared.json does not exist"
  for item in "V3 connector class" "No V4 class" "SNOWPIPE_STREAMING" "payments.auth.v3 topic" "AUTH_EVENTS_RAW_V3 table" "private key externalized" "No V4-only keys"; do
    fail "$item (file not found)"
  done
fi

# =============================================================================
# Section 4: docker-compose.yml — V3 service
# =============================================================================

echo ""
echo "--- [4] docker-compose.yml: kafka-connect-v3 service ---"
echo ""

COMPOSE="$PROJECT_DIR/docker-compose.yml"

if [ -f "$COMPOSE" ]; then
  pass "docker-compose.yml exists"

  if grep -q 'kafka-connect-v3' "$COMPOSE"; then
    pass "kafka-connect-v3 service defined"
  else
    fail "kafka-connect-v3 service missing from docker-compose.yml"
  fi

  if grep -q '8084' "$COMPOSE"; then
    pass "Port 8084 mapped for V3 connector"
  else
    fail "Port 8084 not mapped for V3 connector"
  fi

  if grep -q 'snowflake-connector-v3-group\|v3-group' "$COMPOSE"; then
    pass "Separate consumer group for V3 connector"
  else
    fail "V3 connector missing dedicated consumer group"
  fi
else
  fail "docker-compose.yml does not exist"
  fail "kafka-connect-v3 service not verified (file not found)"
  fail "Port 8084 not verified (file not found)"
  fail "Consumer group not verified (file not found)"
fi

# =============================================================================
# Section 5: Schemachange migrations
# =============================================================================

echo ""
echo "--- [5] Schemachange migrations ---"
echo ""

MIGRATION_V3_TABLE="$PROJECT_DIR/schemachange/migrations/V1.9.0__create_v3_raw_table.sql"
MIGRATION_V3_GRANTS="$PROJECT_DIR/schemachange/migrations/V1.10.0__grant_v3_table_privileges.sql"

if [ -f "$MIGRATION_V3_TABLE" ]; then
  pass "V1.9.0 migration exists (AUTH_EVENTS_RAW_V3 table)"

  if grep -qi 'AUTH_EVENTS_RAW_V3' "$MIGRATION_V3_TABLE"; then
    pass "AUTH_EVENTS_RAW_V3 table defined"
  else
    fail "AUTH_EVENTS_RAW_V3 not found in V1.9.0 migration"
  fi

  if grep -qi 'RECORD_CONTENT.*VARIANT\|VARIANT.*RECORD_CONTENT' "$MIGRATION_V3_TABLE"; then
    pass "RECORD_CONTENT VARIANT column present (V3 schema)"
  else
    fail "RECORD_CONTENT VARIANT column missing"
  fi

  if grep -qi 'RECORD_METADATA.*VARIANT\|VARIANT.*RECORD_METADATA' "$MIGRATION_V3_TABLE"; then
    pass "RECORD_METADATA VARIANT column present (V3 schema)"
  else
    fail "RECORD_METADATA VARIANT column missing"
  fi
else
  fail "V1.9.0 migration (create_v3_raw_table.sql) does not exist"
  fail "AUTH_EVENTS_RAW_V3 table definition not verified"
  fail "RECORD_CONTENT VARIANT not verified"
  fail "RECORD_METADATA VARIANT not verified"
fi

if [ -f "$MIGRATION_V3_GRANTS" ]; then
  pass "V1.10.0 migration exists (V3 table grants)"

  if grep -qi 'GRANT INSERT' "$MIGRATION_V3_GRANTS" && grep -qi 'AUTH_EVENTS_RAW_V3' "$MIGRATION_V3_GRANTS"; then
    pass "INSERT grant on AUTH_EVENTS_RAW_V3 present"
  else
    fail "INSERT grant on AUTH_EVENTS_RAW_V3 missing"
  fi

  if grep -qi 'PAYMENTS_INGEST_ROLE' "$MIGRATION_V3_GRANTS"; then
    pass "PAYMENTS_INGEST_ROLE referenced in grants"
  else
    fail "PAYMENTS_INGEST_ROLE not referenced"
  fi
else
  fail "V1.10.0 migration (grant_v3_table_privileges.sql) does not exist"
  fail "INSERT grant not verified (file not found)"
  fail "PAYMENTS_INGEST_ROLE not verified (file not found)"
fi

# =============================================================================
# Section 6: Streamlit benchmark page
# =============================================================================

echo ""
echo "--- [6] curated_analytics/pages/4_Connector_Benchmark.py ---"
echo ""

BENCHMARK_PAGE="$PROJECT_DIR/curated_analytics/pages/4_Connector_Benchmark.py"

if [ -f "$BENCHMARK_PAGE" ]; then
  pass "4_Connector_Benchmark.py exists"

  if grep -q 'AUTH_EVENTS_RAW_V3' "$BENCHMARK_PAGE"; then
    pass "V3 table AUTH_EVENTS_RAW_V3 queried"
  else
    fail "V3 table AUTH_EVENTS_RAW_V3 not referenced"
  fi

  if grep -q 'AUTH_EVENTS_RAW' "$BENCHMARK_PAGE" && ! grep -q 'AUTH_EVENTS_RAW_V3' "$BENCHMARK_PAGE"; then
    fail "V4 table AUTH_EVENTS_RAW not referenced (only V3 found)"
  else
    pass "V4 table AUTH_EVENTS_RAW queried"
  fi

  if grep -q 'plotly_dark\|plotly dark' "$BENCHMARK_PAGE"; then
    pass "plotly_dark template used (consistent with other pages)"
  else
    fail "plotly_dark template not used"
  fi

  if grep -q 'st.rerun\|auto.refresh\|auto_refresh' "$BENCHMARK_PAGE"; then
    pass "Auto-refresh mechanism present"
  else
    fail "Auto-refresh mechanism missing"
  fi

  if grep -q 'get_connection' "$BENCHMARK_PAGE"; then
    pass "Uses shared get_connection() from streamlit_app"
  else
    fail "Does not use shared get_connection()"
  fi
else
  fail "4_Connector_Benchmark.py does not exist"
  for item in "V3 table queried" "V4 table queried" "plotly_dark template" "auto-refresh" "get_connection"; do
    fail "$item (file not found)"
  done
fi

# =============================================================================
# Section 7: Generator dual-topic publish
# =============================================================================

echo ""
echo "--- [7] Generator dual-topic publish ---"
echo ""

GENERATOR_CONFIG="$PROJECT_DIR/generator/config.py"
GENERATOR_MAIN="$PROJECT_DIR/generator/main.py"

if [ -f "$GENERATOR_CONFIG" ]; then
  if grep -q 'V3_TOPIC\|payments.auth.v3' "$GENERATOR_CONFIG"; then
    pass "V3 topic referenced in generator/config.py"
  else
    fail "V3 topic not in generator/config.py"
  fi
else
  fail "generator/config.py not found"
fi

if [ -f "$GENERATOR_MAIN" ]; then
  if grep -q 'V3_TOPIC\|payments.auth.v3' "$GENERATOR_MAIN"; then
    pass "V3 topic referenced in generator/main.py (dual-publish)"
  else
    fail "V3 topic not in generator/main.py (dual-publish missing)"
  fi
else
  fail "generator/main.py not found"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
