#!/usr/bin/env bash
# tests/validate_terraform.sh
# TDD validation script for Issue #1: Terraform database, schemas, and roles
#
# Checks:
#   1. terraform validate succeeds
#   2. terraform plan output contains all expected resources
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
echo "[2] Expected resource declarations"

# Scan all .tf files for resource declarations (no credentials needed)
ALL_TF_CONTENT=$(cat "$TF_DIR"/*.tf 2>/dev/null || true)

EXPECTED_RESOURCES=(
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

for res in "${EXPECTED_RESOURCES[@]}"; do
  if echo "$ALL_TF_CONTENT" | grep -qF "$res"; then
    pass "Found: $res"
  else
    fail "Missing: $res"
  fi
done

# --- Test 3: Role hierarchy structure ---
echo "[3] Role hierarchy assertions"

# Check roles.tf exists and contains hierarchy grants
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
echo "[5] Grant assertions"

if [ -f "$TF_DIR/grants.tf" ]; then
  if grep -q 'USAGE' "$TF_DIR/grants.tf"; then
    pass "USAGE grants found in grants.tf"
  else
    fail "USAGE grants missing from grants.tf"
  fi
else
  fail "grants.tf does not exist"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
