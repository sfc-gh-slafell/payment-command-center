#!/usr/bin/env bash
# tests/validate_dbt.sh
# TDD validation for dbt project
#
# Issue #24: dbt project setup and source definitions
# Issue #25: curated dynamic table models and tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
DBT_DIR="$PROJECT_DIR/dbt"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "=== dbt Project Validation Tests ==="
echo ""

# =============================================================================
# Issue #24: dbt project setup
# =============================================================================

echo "--- Issue #24: dbt Project Setup ---"
echo ""

echo "[1] dbt/dbt_project.yml"
if [ -f "$DBT_DIR/dbt_project.yml" ]; then
  pass "dbt_project.yml exists"
  if grep -qi 'CURATED\|curated' "$DBT_DIR/dbt_project.yml"; then
    pass "Target schema CURATED configured"
  else
    fail "Target schema CURATED missing"
  fi
  if grep -qi 'model\|models' "$DBT_DIR/dbt_project.yml"; then
    pass "models path configured"
  else
    fail "models path missing"
  fi
else
  fail "dbt_project.yml does not exist"
  fail "Target schema CURATED missing (file not found)"
  fail "models path missing (file not found)"
fi

echo "[2] dbt/profiles.yml"
if [ -f "$DBT_DIR/profiles.yml" ]; then
  pass "profiles.yml exists"
  if grep -qi 'PAYMENTS_ADMIN_WH\|payments_admin_wh' "$DBT_DIR/profiles.yml"; then
    pass "PAYMENTS_ADMIN_WH warehouse configured"
  else
    fail "PAYMENTS_ADMIN_WH warehouse missing"
  fi
  if grep -qi 'key.*pair\|private_key' "$DBT_DIR/profiles.yml"; then
    pass "Key-pair auth configured"
  else
    fail "Key-pair auth missing"
  fi
  if grep -qi 'PAYMENTS_DB\|payments_db' "$DBT_DIR/profiles.yml"; then
    pass "PAYMENTS_DB database configured"
  else
    fail "PAYMENTS_DB database missing"
  fi
else
  fail "profiles.yml does not exist"
  for item in "PAYMENTS_ADMIN_WH" "Key-pair auth" "PAYMENTS_DB"; do
    fail "$item missing (file not found)"
  done
fi

echo "[3] dbt/packages.yml"
if [ -f "$DBT_DIR/packages.yml" ]; then
  pass "packages.yml exists"
  if grep -qi 'dbt-labs/dbt_utils\|snowflake\|dbt_snowflake' "$DBT_DIR/packages.yml"; then
    pass "Snowflake adapter/utils package listed"
  else
    fail "Snowflake package missing"
  fi
else
  fail "packages.yml does not exist"
  fail "Snowflake package missing (file not found)"
fi

echo "[4] dbt/models/staging/stg_auth_events.yml"
STAGING_YML="$DBT_DIR/models/staging/stg_auth_events.yml"
if [ -f "$STAGING_YML" ]; then
  pass "stg_auth_events.yml exists"
  if grep -qi 'AUTH_EVENTS_RAW\|auth_events_raw' "$STAGING_YML"; then
    pass "AUTH_EVENTS_RAW source defined"
  else
    fail "AUTH_EVENTS_RAW source missing"
  fi
  if grep -qi 'not_null' "$STAGING_YML"; then
    pass "not_null tests configured"
  else
    fail "not_null tests missing"
  fi
  if grep -qi 'accepted_values' "$STAGING_YML"; then
    pass "accepted_values tests configured"
  else
    fail "accepted_values tests missing"
  fi
else
  fail "stg_auth_events.yml does not exist"
  fail "AUTH_EVENTS_RAW source missing (file not found)"
  fail "not_null tests missing (file not found)"
  fail "accepted_values tests missing (file not found)"
fi

# =============================================================================
# Issue #25: curated dynamic table models
# =============================================================================

echo ""
echo "--- Issue #25: Curated Dynamic Table Models ---"
echo ""

CURATED="$DBT_DIR/models/curated"

echo "[5] dt_auth_enriched.sql"
if [ -f "$CURATED/dt_auth_enriched.sql" ]; then
  pass "dt_auth_enriched.sql exists"
  if grep -qi 'dynamic_table\|DYNAMIC' "$CURATED/dt_auth_enriched.sql"; then
    pass "materialized=dynamic_table configured"
  else
    fail "materialized=dynamic_table missing"
  fi
  if grep -qi '5.*min\|300.*second\|target_lag.*5' "$CURATED/dt_auth_enriched.sql"; then
    pass "5min target_lag configured"
  else
    fail "5min target_lag missing"
  fi
  if grep -qi 'latency_tier\|FAST\|SLOW\|CRITICAL' "$CURATED/dt_auth_enriched.sql"; then
    pass "latency_tier enrichment present"
  else
    fail "latency_tier enrichment missing"
  fi
  if grep -qi 'value_tier\|HIGH.*MEDIUM\|STANDARD' "$CURATED/dt_auth_enriched.sql"; then
    pass "value_tier enrichment present"
  else
    fail "value_tier enrichment missing"
  fi
else
  fail "dt_auth_enriched.sql does not exist"
  for item in "dynamic_table config" "5min target_lag" "latency_tier" "value_tier"; do
    fail "$item missing (file not found)"
  done
fi

echo "[6] dt_auth_hourly.sql"
if [ -f "$CURATED/dt_auth_hourly.sql" ]; then
  pass "dt_auth_hourly.sql exists"
  if grep -qi 'dynamic_table\|DYNAMIC' "$CURATED/dt_auth_hourly.sql"; then
    pass "materialized=dynamic_table configured"
  else
    fail "materialized=dynamic_table missing"
  fi
  if grep -qi '30.*min\|30 minutes\|target_lag.*30' "$CURATED/dt_auth_hourly.sql"; then
    pass "30min target_lag configured"
  else
    fail "30min target_lag missing"
  fi
  # Critical: SUM/COUNT not plain AVG for latency reaggregation
  if grep -qi 'SUM.*latency.*COUNT\|latency.*SUM.*COUNT' "$CURATED/dt_auth_hourly.sql"; then
    pass "SUM/COUNT latency pattern used"
  else
    fail "SUM/COUNT latency pattern missing (plain AVG would break reaggregation)"
  fi
else
  fail "dt_auth_hourly.sql does not exist"
  fail "dynamic_table config missing (file not found)"
  fail "30min target_lag missing (file not found)"
  fail "SUM/COUNT latency pattern missing (file not found)"
fi

echo "[7] dt_auth_daily.sql"
if [ -f "$CURATED/dt_auth_daily.sql" ]; then
  pass "dt_auth_daily.sql exists"
  if grep -qi 'dynamic_table\|DYNAMIC' "$CURATED/dt_auth_daily.sql"; then
    pass "materialized=dynamic_table configured"
  else
    fail "materialized=dynamic_table missing"
  fi
  if grep -qi '1.*hour\|60.*min\|1 hour\|target_lag.*1' "$CURATED/dt_auth_daily.sql"; then
    pass "1hr target_lag configured"
  else
    fail "1hr target_lag missing"
  fi
  if grep -qi 'PERCENTILE_CONT\|p95\|percentile' "$CURATED/dt_auth_daily.sql"; then
    pass "PERCENTILE_CONT for p95 present"
  else
    fail "PERCENTILE_CONT missing"
  fi
else
  fail "dt_auth_daily.sql does not exist"
  for item in "dynamic_table config" "1hr target_lag" "PERCENTILE_CONT"; do
    fail "$item missing (file not found)"
  done
fi

echo "[8] curated.yml"
if [ -f "$CURATED/curated.yml" ]; then
  pass "curated.yml exists"
  if grep -qi 'columns\|tests\|description' "$CURATED/curated.yml"; then
    pass "Column docs and tests configured"
  else
    fail "Column docs and tests missing"
  fi
else
  fail "curated.yml does not exist"
  fail "Column docs and tests missing (file not found)"
fi

echo "[9] dbt/tests/assert_no_null_event_ids.sql"
if [ -f "$DBT_DIR/tests/assert_no_null_event_ids.sql" ]; then
  pass "Singular test assert_no_null_event_ids.sql exists"
  if grep -qi 'event_id\|null\|NULL' "$DBT_DIR/tests/assert_no_null_event_ids.sql"; then
    pass "Test checks event_id for nulls"
  else
    fail "Test does not check event_id"
  fi
else
  fail "assert_no_null_event_ids.sql does not exist"
  fail "Test does not check event_id (file not found)"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
