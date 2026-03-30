#!/usr/bin/env bash
# tests/validate_spcs.sh
# TDD validation for SPCS service spec and Dockerfile
#
# Issue #21: Multi-stage Dockerfile and SPCS service spec
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "=== SPCS Service Spec Validation Tests ==="
echo ""

# --- Test 1: app/Dockerfile ---
echo "[1] app/Dockerfile (multi-stage)"

if [ -f "$PROJECT_DIR/app/Dockerfile" ]; then
  pass "app/Dockerfile exists"

  if grep -qi 'node.*18\|node:18\|FROM node' "$PROJECT_DIR/app/Dockerfile"; then
    pass "Node 18 build stage present"
  else
    fail "Node 18 build stage missing"
  fi

  if grep -qi 'npm.*build\|npm run build' "$PROJECT_DIR/app/Dockerfile"; then
    pass "npm run build present"
  else
    fail "npm run build missing"
  fi

  if grep -qi 'python.*3.11\|python:3.11' "$PROJECT_DIR/app/Dockerfile"; then
    pass "Python 3.11 runtime stage present"
  else
    fail "Python 3.11 runtime stage missing"
  fi

  if grep -qi 'uvicorn' "$PROJECT_DIR/app/Dockerfile"; then
    pass "uvicorn CMD present"
  else
    fail "uvicorn CMD missing"
  fi

  if grep -qi '8080' "$PROJECT_DIR/app/Dockerfile"; then
    pass "Port 8080 exposed"
  else
    fail "Port 8080 not exposed"
  fi

  # Multi-stage: check FROM count >= 2
  FROM_COUNT=$(grep -c "^FROM" "$PROJECT_DIR/app/Dockerfile" || true)
  if [ "$FROM_COUNT" -ge 2 ]; then
    pass "Multi-stage build (>= 2 FROM statements)"
  else
    fail "Single-stage build (need >= 2 FROM for multi-stage)"
  fi
else
  fail "app/Dockerfile does not exist"
  for item in "Node 18 build stage" "npm run build" "Python 3.11 runtime stage" "uvicorn CMD" "Port 8080 exposed" "Multi-stage build"; do
    fail "$item missing (file not found)"
  done
fi

# --- Test 2: spcs/service_spec.yaml ---
echo "[2] spcs/service_spec.yaml"

if [ -f "$PROJECT_DIR/spcs/service_spec.yaml" ]; then
  pass "service_spec.yaml exists"

  if grep -qi '8080' "$PROJECT_DIR/spcs/service_spec.yaml"; then
    pass "Port 8080 configured"
  else
    fail "Port 8080 not configured"
  fi

  if grep -qi 'health\|/health\|readiness' "$PROJECT_DIR/spcs/service_spec.yaml"; then
    pass "readinessProbe /health configured"
  else
    fail "readinessProbe /health missing"
  fi

  if grep -qi 'SNOWFLAKE_WAREHOUSE\|SNOWFLAKE_DATABASE\|APP_PORT' "$PROJECT_DIR/spcs/service_spec.yaml"; then
    pass "Environment variables configured"
  else
    fail "Environment variables missing"
  fi

  if grep -qi 'endpoint\|public' "$PROJECT_DIR/spcs/service_spec.yaml"; then
    pass "Public endpoint configured"
  else
    fail "Public endpoint missing"
  fi

  if grep -qi 'memory\|cpu\|resource' "$PROJECT_DIR/spcs/service_spec.yaml"; then
    pass "Resource requests/limits configured"
  else
    fail "Resource requests/limits missing"
  fi
else
  fail "service_spec.yaml does not exist"
  for item in "Port 8080" "readinessProbe" "Environment variables" "Public endpoint" "Resource limits"; do
    fail "$item missing (file not found)"
  done
fi

# --- Test 3: spcs/snowflake.yml ---
echo "[3] spcs/snowflake.yml"

if [ -f "$PROJECT_DIR/spcs/snowflake.yml" ]; then
  pass "spcs/snowflake.yml exists"
  if grep -qi 'streamlit\|service\|spcs\|deploy' "$PROJECT_DIR/spcs/snowflake.yml"; then
    pass "SPCS deployment config present"
  else
    fail "SPCS deployment config missing"
  fi
else
  fail "spcs/snowflake.yml does not exist"
  fail "SPCS deployment config missing (file not found)"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
