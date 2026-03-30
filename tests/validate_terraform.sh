#!/usr/bin/env bash
# tests/validate_terraform.sh
# TDD validation script for Payment Authorization Command Center
#
# Issue #1: database, schemas, roles, grants
# Issue #2: warehouses, compute pool, image repo, stages, resource monitor
#
# Usage: ./tests/validate_terraform.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "=== Terraform Validation Tests ==="
echo ""

# --- Test 1: terraform validate ---
echo "[1] terraform validate"
cd "$TF_DIR"
if terraform validate -no-color > /dev/null 2>&1; then
  pass "terraform validate succeeded"
else
  fail "terraform validate failed"
fi

# --- Test 2: Expected resource declarations in .tf files ---
echo "[2] Expected resource declarations (Issue #1)"

# Scan all .tf files for resource declarations (no credentials needed)
ALL_TF_CONTENT=$(cat "$TF_DIR"/*.tf 2>/dev/null || true)

EXPECTED_RESOURCES_ISSUE1=(
  'resource "snowflake_database" "payments_db"'
  'resource "snowflake_schema" "raw"'
  'resource "snowflake_schema" "serve"'
  'resource "snowflake_schema" "curated"'
  'resource "snowflake_schema" "app"'
  'resource "snowflake_account_role" "payments_admin"'
  'resource "snowflake_account_role" "payments_app"'
  'resource "snowflake_account_role" "payments_ingest"'
  'resource "snowflake_account_role" "payments_ops"'
  'resource "snowflake_grant_account_role" "admin_to_sysadmin"'
  'resource "snowflake_grant_account_role" "app_to_admin"'
  'resource "snowflake_grant_account_role" "ingest_to_admin"'
  'resource "snowflake_grant_account_role" "ops_to_admin"'
)

for res in "${EXPECTED_RESOURCES_ISSUE1[@]}"; do
  if echo "$ALL_TF_CONTENT" | grep -qF "$res"; then
    pass "Found: $res"
  else
    fail "Missing: $res"
  fi
done

# --- Test 3: Role hierarchy structure ---
echo "[3] Role hierarchy assertions"

if [ -f "$TF_DIR/roles.tf" ]; then
  if grep -q 'PAYMENTS_ADMIN_ROLE' "$TF_DIR/roles.tf" && \
     grep -q 'PAYMENTS_APP_ROLE' "$TF_DIR/roles.tf" && \
     grep -q 'PAYMENTS_INGEST_ROLE' "$TF_DIR/roles.tf" && \
     grep -q 'PAYMENTS_OPS_ROLE' "$TF_DIR/roles.tf"; then
    pass "All four roles defined in roles.tf"
  else
    fail "Not all four roles defined in roles.tf"
  fi

  if grep -q 'SYSADMIN' "$TF_DIR/roles.tf"; then
    pass "SYSADMIN parent reference found in roles.tf"
  else
    fail "SYSADMIN parent reference missing from roles.tf"
  fi
else
  fail "roles.tf does not exist"
fi

# --- Test 4: All schemas present ---
echo "[4] Schema assertions"

if [ -f "$TF_DIR/schemas.tf" ]; then
  for schema in RAW SERVE CURATED APP; do
    if grep -q "\"$schema\"" "$TF_DIR/schemas.tf"; then
      pass "Schema $schema defined in schemas.tf"
    else
      fail "Schema $schema missing from schemas.tf"
    fi
  done
else
  fail "schemas.tf does not exist"
fi

# --- Test 5: Grants file exists with schema USAGE ---
echo "[5] Grant assertions (Issue #1)"

if [ -f "$TF_DIR/grants.tf" ]; then
  if grep -q 'USAGE' "$TF_DIR/grants.tf"; then
    pass "USAGE grants found in grants.tf"
  else
    fail "USAGE grants missing from grants.tf"
  fi
else
  fail "grants.tf does not exist"
fi

# =============================================================================
# Issue #2: Warehouses, compute pool, image repo, stages, resource monitor
# =============================================================================

echo ""
echo "--- Issue #2: Warehouses, Compute, Stages ---"
echo ""

# --- Test 6: warehouses.tf exists with all three warehouses ---
echo "[6] Warehouse declarations"

if [ -f "$TF_DIR/warehouses.tf" ]; then
  pass "warehouses.tf exists"

  # PAYMENTS_REFRESH_WH — standard warehouse (native resource)
  if echo "$ALL_TF_CONTENT" | grep -qF 'resource "snowflake_warehouse" "payments_refresh_wh"'; then
    pass "Found: snowflake_warehouse.payments_refresh_wh"
  else
    fail "Missing: snowflake_warehouse.payments_refresh_wh"
  fi

  # PAYMENTS_ADMIN_WH — standard warehouse (native resource)
  if echo "$ALL_TF_CONTENT" | grep -qF 'resource "snowflake_warehouse" "payments_admin_wh"'; then
    pass "Found: snowflake_warehouse.payments_admin_wh"
  else
    fail "Missing: snowflake_warehouse.payments_admin_wh"
  fi

  # PAYMENTS_INTERACTIVE_WH — interactive warehouse (via snowflake_execute)
  if echo "$ALL_TF_CONTENT" | grep -qF 'resource "snowflake_execute" "payments_interactive_wh"'; then
    pass "Found: snowflake_execute.payments_interactive_wh"
  else
    fail "Missing: snowflake_execute.payments_interactive_wh"
  fi

  # Verify interactive warehouse DDL contains CREATE INTERACTIVE WAREHOUSE
  if echo "$ALL_TF_CONTENT" | grep -qF 'CREATE INTERACTIVE WAREHOUSE'; then
    pass "CREATE INTERACTIVE WAREHOUSE DDL present"
  else
    fail "CREATE INTERACTIVE WAREHOUSE DDL missing"
  fi

  # Verify auto_suspend settings
  if grep -q 'auto_suspend.*=.*120' "$TF_DIR/warehouses.tf"; then
    pass "PAYMENTS_REFRESH_WH auto_suspend=120"
  else
    fail "PAYMENTS_REFRESH_WH auto_suspend=120 not found"
  fi

  if grep -q 'auto_suspend.*=.*60' "$TF_DIR/warehouses.tf"; then
    pass "PAYMENTS_ADMIN_WH auto_suspend=60"
  else
    fail "PAYMENTS_ADMIN_WH auto_suspend=60 not found"
  fi

  if grep -q 'AUTO_SUSPEND.*=.*86400\|auto_suspend.*86400' "$TF_DIR/warehouses.tf"; then
    pass "PAYMENTS_INTERACTIVE_WH AUTO_SUSPEND=86400"
  else
    fail "PAYMENTS_INTERACTIVE_WH AUTO_SUSPEND=86400 not found"
  fi
else
  fail "warehouses.tf does not exist"
  fail "Missing: snowflake_warehouse.payments_refresh_wh"
  fail "Missing: snowflake_warehouse.payments_admin_wh"
  fail "Missing: snowflake_execute.payments_interactive_wh"
  fail "CREATE INTERACTIVE WAREHOUSE DDL missing"
  fail "PAYMENTS_REFRESH_WH auto_suspend=120 not found"
  fail "PAYMENTS_ADMIN_WH auto_suspend=60 not found"
  fail "PAYMENTS_INTERACTIVE_WH AUTO_SUSPEND=86400 not found"
fi

# --- Test 7: compute_pools.tf with PAYMENTS_DASHBOARD_POOL ---
echo "[7] Compute pool declarations"

if [ -f "$TF_DIR/compute_pools.tf" ]; then
  pass "compute_pools.tf exists"

  if echo "$ALL_TF_CONTENT" | grep -qF 'resource "snowflake_execute" "payments_dashboard_pool"'; then
    pass "Found: snowflake_execute.payments_dashboard_pool"
  else
    fail "Missing: snowflake_execute.payments_dashboard_pool"
  fi

  if echo "$ALL_TF_CONTENT" | grep -qF 'CREATE COMPUTE POOL'; then
    pass "CREATE COMPUTE POOL DDL present"
  else
    fail "CREATE COMPUTE POOL DDL missing"
  fi

  if grep -q 'PAYMENTS_DASHBOARD_POOL' "$TF_DIR/compute_pools.tf"; then
    pass "PAYMENTS_DASHBOARD_POOL name present"
  else
    fail "PAYMENTS_DASHBOARD_POOL name missing"
  fi

  if grep -q 'CPU_X64_S' "$TF_DIR/compute_pools.tf"; then
    pass "CPU_X64_S instance family present"
  else
    fail "CPU_X64_S instance family missing"
  fi
else
  fail "compute_pools.tf does not exist"
  fail "Missing: snowflake_execute.payments_dashboard_pool"
  fail "CREATE COMPUTE POOL DDL missing"
  fail "PAYMENTS_DASHBOARD_POOL name missing"
  fail "CPU_X64_S instance family missing"
fi

# --- Test 8: stages.tf with image repo and spec stage ---
echo "[8] Stage and image repository declarations"

if [ -f "$TF_DIR/stages.tf" ]; then
  pass "stages.tf exists"

  # Image repository via snowflake_execute
  if echo "$ALL_TF_CONTENT" | grep -qF 'resource "snowflake_execute" "dashboard_repo"'; then
    pass "Found: snowflake_execute.dashboard_repo"
  else
    fail "Missing: snowflake_execute.dashboard_repo"
  fi

  if echo "$ALL_TF_CONTENT" | grep -q 'CREATE IMAGE REPOSITORY\|CREATE OR REPLACE IMAGE REPOSITORY'; then
    pass "CREATE IMAGE REPOSITORY DDL present"
  else
    fail "CREATE IMAGE REPOSITORY DDL missing"
  fi

  if grep -q 'DASHBOARD_REPO' "$TF_DIR/stages.tf"; then
    pass "DASHBOARD_REPO name present"
  else
    fail "DASHBOARD_REPO name missing"
  fi

  # Spec stage (native snowflake_stage_internal or snowflake_execute)
  if echo "$ALL_TF_CONTENT" | grep -q 'resource "snowflake_stage_internal" "specs"\|resource "snowflake_stage" "specs"\|resource "snowflake_execute" "specs_stage"'; then
    pass "Found: specs stage resource"
  else
    fail "Missing: specs stage resource"
  fi

  if grep -q 'SPECS' "$TF_DIR/stages.tf"; then
    pass "SPECS stage name present"
  else
    fail "SPECS stage name missing"
  fi
else
  fail "stages.tf does not exist"
  fail "Missing: snowflake_execute.dashboard_repo"
  fail "CREATE IMAGE REPOSITORY DDL missing"
  fail "DASHBOARD_REPO name missing"
  fail "Missing: specs stage resource"
  fail "SPECS stage name missing"
fi

# --- Test 9: Warehouse USAGE grants in grants.tf ---
echo "[9] Warehouse grants (Issue #2)"

if [ -f "$TF_DIR/grants.tf" ]; then
  # APP role should have USAGE on interactive WH
  if grep -q 'app.*interactive\|interactive.*app\|PAYMENTS_INTERACTIVE_WH.*PAYMENTS_APP\|PAYMENTS_APP.*PAYMENTS_INTERACTIVE_WH' "$TF_DIR/grants.tf"; then
    pass "APP role warehouse grant references interactive WH"
  else
    fail "APP role warehouse grant for interactive WH missing"
  fi

  # APP role should have USAGE on admin WH
  if grep -q 'app.*admin_wh\|PAYMENTS_ADMIN_WH.*PAYMENTS_APP\|PAYMENTS_APP.*PAYMENTS_ADMIN_WH' "$TF_DIR/grants.tf"; then
    pass "APP role warehouse grant references admin WH"
  else
    fail "APP role warehouse grant for admin WH missing"
  fi

  # BIND SERVICE ENDPOINT grant for APP role
  if grep -q 'BIND SERVICE ENDPOINT' "$TF_DIR/grants.tf"; then
    pass "BIND SERVICE ENDPOINT grant present"
  else
    fail "BIND SERVICE ENDPOINT grant missing"
  fi
else
  fail "grants.tf does not exist"
fi

# --- Test 10: Resource monitor ---
echo "[10] Resource monitor"

if echo "$ALL_TF_CONTENT" | grep -qF 'resource "snowflake_resource_monitor"'; then
  pass "Found: snowflake_resource_monitor resource"
else
  fail "Missing: snowflake_resource_monitor resource"
fi

if echo "$ALL_TF_CONTENT" | grep -q 'credit_quota'; then
  pass "credit_quota configured"
else
  fail "credit_quota not configured"
fi

# --- Test 11: Updated outputs ---
echo "[11] Output assertions (Issue #2)"

if [ -f "$TF_DIR/outputs.tf" ]; then
  if grep -q 'warehouse_names\|warehouse' "$TF_DIR/outputs.tf"; then
    pass "Warehouse outputs present"
  else
    fail "Warehouse outputs missing from outputs.tf"
  fi
else
  fail "outputs.tf does not exist"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
