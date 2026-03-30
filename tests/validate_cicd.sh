#!/usr/bin/env bash
# tests/validate_cicd.sh
# TDD validation for CI/CD GitHub Actions workflows
#
# Issue #26: CI workflow
# Issue #27: CD workflow
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
GH_DIR="$PROJECT_DIR/.github/workflows"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "=== CI/CD Workflow Validation Tests ==="
echo ""

# =============================================================================
# Issue #26: CI workflow
# =============================================================================

echo "--- Issue #26: CI Workflow ---"
echo ""

echo "[1] .github/workflows/ci.yml"
if [ -f "$GH_DIR/ci.yml" ]; then
  pass "ci.yml exists"

  if grep -qi 'pull_request\|on.*pr\|push' "$GH_DIR/ci.yml"; then
    pass "Triggered on pull_request"
  else
    fail "PR trigger missing"
  fi

  if grep -qi 'ruff\|pylint\|flake8\|python.*lint' "$GH_DIR/ci.yml"; then
    pass "Python lint job present"
  else
    fail "Python lint job missing"
  fi

  if grep -qi 'eslint\|tsc\|typescript' "$GH_DIR/ci.yml"; then
    pass "TypeScript lint job present"
  else
    fail "TypeScript lint job missing"
  fi

  if grep -qi 'sqlfluff\|sql.*lint' "$GH_DIR/ci.yml"; then
    pass "SQL lint job present"
  else
    fail "SQL lint job missing"
  fi

  if grep -qi 'docker.*build\|docker build' "$GH_DIR/ci.yml"; then
    pass "Docker build job present"
  else
    fail "Docker build job missing"
  fi

  if grep -qi 'dbt.*compile\|dbt compile' "$GH_DIR/ci.yml"; then
    pass "dbt compile job present"
  else
    fail "dbt compile job missing"
  fi
else
  fail "ci.yml does not exist"
  for item in "PR trigger" "Python lint" "TypeScript lint" "SQL lint" "Docker build" "dbt compile"; do
    fail "$item missing (file not found)"
  done
fi

# =============================================================================
# Issue #27: CD workflow
# =============================================================================

echo ""
echo "--- Issue #27: CD Workflow ---"
echo ""

echo "[2] .github/workflows/deploy.yml"
if [ -f "$GH_DIR/deploy.yml" ]; then
  pass "deploy.yml exists"

  if grep -qi 'main.*push\|push.*main\|branches.*main' "$GH_DIR/deploy.yml"; then
    pass "Triggered on push to main"
  else
    fail "Push-to-main trigger missing"
  fi

  if grep -qi 'terraform.*apply\|terraform apply' "$GH_DIR/deploy.yml"; then
    pass "terraform apply job present"
  else
    fail "terraform apply job missing"
  fi

  if grep -qi 'schemachange\|schema.*change' "$GH_DIR/deploy.yml"; then
    pass "schemachange deploy job present"
  else
    fail "schemachange deploy job missing"
  fi

  if grep -qi 'dbt.*run\|dbt run' "$GH_DIR/deploy.yml"; then
    pass "dbt run job present"
  else
    fail "dbt run job missing"
  fi

  if grep -qi 'docker.*push\|registry.*push' "$GH_DIR/deploy.yml"; then
    pass "Docker push job present"
  else
    fail "Docker push job missing"
  fi

  if grep -qi 'needs:\|depends' "$GH_DIR/deploy.yml"; then
    pass "Job dependency chain configured"
  else
    fail "Job dependency chain missing"
  fi

  if grep -qi 'secrets\.\|SNOWFLAKE_ACCOUNT\|env:' "$GH_DIR/deploy.yml"; then
    pass "Secrets referenced from GitHub secrets"
  else
    fail "Secrets not properly referenced"
  fi
else
  fail "deploy.yml does not exist"
  for item in "Push-to-main trigger" "terraform apply" "schemachange deploy" "dbt run" "Docker push" "Job dependencies" "Secrets management"; do
    fail "$item missing (file not found)"
  done
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
