#!/usr/bin/env bash
# tests/validate_skeleton.sh
# TDD validation script for repository skeleton and dev tooling
#
# Issue #5: Repository skeleton and dev tooling
#
# Usage: ./tests/validate_skeleton.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "=== Repository Skeleton Validation Tests ==="
echo ""

# --- Test 1: All directories from spec Section 8 exist ---
echo "[1] Directory structure (spec Section 8)"

REQUIRED_DIRS=(
  "terraform"
  "schemachange/migrations"
  "dbt/models/staging"
  "dbt/models/curated"
  "dbt/tests"
  "generator"
  "kafka-connect"
  "fallback_ingest"
  "app/backend/routes"
  "app/backend/queries"
  "app/frontend/src/components"
  "app/frontend/src/hooks"
  "app/frontend/src/types"
  "app/frontend/public"
  "spcs"
  ".github/workflows"
)

for dir in "${REQUIRED_DIRS[@]}"; do
  if [ -d "$PROJECT_DIR/$dir" ]; then
    pass "Directory $dir exists"
  else
    fail "Directory $dir missing"
  fi
done

# --- Test 2: .gitignore prevents committing secrets and build artifacts ---
echo "[2] .gitignore coverage"

GITIGNORE="$PROJECT_DIR/.gitignore"

if [ -f "$GITIGNORE" ]; then
  pass ".gitignore exists"

  REQUIRED_PATTERNS=(
    "*.tfstate"
    "node_modules"
    "__pycache__"
    ".env"
    "*.p8"
    "dist/"
    "build/"
  )

  for pattern in "${REQUIRED_PATTERNS[@]}"; do
    if grep -qF "$pattern" "$GITIGNORE"; then
      pass ".gitignore contains $pattern"
    else
      fail ".gitignore missing $pattern"
    fi
  done
else
  fail ".gitignore does not exist"
  for pattern in "*.tfstate" "node_modules" "__pycache__" ".env" "*.p8" "dist/" "build/"; do
    fail ".gitignore missing $pattern (file not found)"
  done
fi

# --- Test 3: Root snowflake.yml placeholder ---
echo "[3] Root snowflake.yml"

SNOWFLAKE_YML="$PROJECT_DIR/snowflake.yml"

if [ -f "$SNOWFLAKE_YML" ]; then
  pass "snowflake.yml exists"

  if grep -qi 'definition_version\|connection' "$SNOWFLAKE_YML"; then
    pass "snowflake.yml has connection/definition structure"
  else
    fail "snowflake.yml missing connection/definition structure"
  fi
else
  fail "snowflake.yml does not exist"
  fail "snowflake.yml missing connection/definition structure"
fi

# --- Test 4: Makefile or Taskfile with required targets ---
echo "[4] Makefile / Taskfile targets"

if [ -f "$PROJECT_DIR/Makefile" ] || [ -f "$PROJECT_DIR/Taskfile.yml" ]; then
  pass "Makefile or Taskfile.yml exists"

  TASKFILE="$PROJECT_DIR/Makefile"
  if [ -f "$PROJECT_DIR/Taskfile.yml" ]; then
    TASKFILE="$PROJECT_DIR/Taskfile.yml"
  fi

  REQUIRED_TARGETS=(
    "tf-plan"
    "tf-apply"
    "schema-deploy"
    "dbt-run"
    "gen-start"
    "app-build"
    "app-deploy"
  )

  for target in "${REQUIRED_TARGETS[@]}"; do
    if grep -q "$target" "$TASKFILE"; then
      pass "Target $target present"
    else
      fail "Target $target missing"
    fi
  done

  # Verify help target works (Makefile only)
  if [ -f "$PROJECT_DIR/Makefile" ]; then
    if make -C "$PROJECT_DIR" help > /dev/null 2>&1; then
      pass "make help succeeds"
    else
      fail "make help fails"
    fi
  fi
else
  fail "Neither Makefile nor Taskfile.yml exists"
  for target in tf-plan tf-apply schema-deploy dbt-run gen-start app-build app-deploy; do
    fail "Target $target missing (file not found)"
  done
  fail "make help fails (file not found)"
fi

# --- Test 5: README.md has architecture and component info ---
echo "[5] README.md content"

README="$PROJECT_DIR/README.md"

if [ -f "$README" ]; then
  pass "README.md exists"

  if grep -qi 'architecture\|diagram' "$README"; then
    pass "README contains architecture reference"
  else
    fail "README missing architecture reference"
  fi

  if grep -qi 'quickstart\|getting started\|quick start' "$README"; then
    pass "README contains quickstart section"
  else
    fail "README missing quickstart section"
  fi
else
  fail "README.md does not exist"
  fail "README missing architecture reference"
  fail "README missing quickstart section"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
