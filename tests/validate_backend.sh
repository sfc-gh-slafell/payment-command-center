#!/usr/bin/env bash
# tests/validate_backend.sh
# TDD validation for backend API
#
# Issue #11: Snowflake client and dual connection pools
# Issue #12: SQL query templates
# Issue #13: Route handlers and Pydantic models
# Issue #14: Latency endpoint and freshness logic
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
BE_DIR="$PROJECT_DIR/app/backend"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "=== Backend API Validation Tests ==="
echo ""

# =============================================================================
# Issue #11: Snowflake client and dual connection pools
# =============================================================================

echo "--- Issue #11: Snowflake Client ---"
echo ""

echo "[1] app/backend/requirements.txt"
if [ -f "$BE_DIR/requirements.txt" ]; then
  pass "requirements.txt exists"
  for dep in fastapi uvicorn snowflake-connector-python pydantic; do
    if grep -qi "$dep" "$BE_DIR/requirements.txt"; then
      pass "Dependency $dep listed"
    else
      fail "Dependency $dep missing"
    fi
  done
else
  fail "requirements.txt does not exist"
  for dep in fastapi uvicorn snowflake-connector-python pydantic; do
    fail "Dependency $dep missing (file not found)"
  done
fi

echo "[2] app/backend/snowflake_client.py"
if [ -f "$BE_DIR/snowflake_client.py" ]; then
  pass "snowflake_client.py exists"

  if grep -qi 'INTERACTIVE\|interactive_wh\|interactive.*pool' "$BE_DIR/snowflake_client.py"; then
    pass "Interactive WH pool present"
  else
    fail "Interactive WH pool missing"
  fi

  if grep -qi 'ADMIN\|admin_wh\|standard.*pool' "$BE_DIR/snowflake_client.py"; then
    pass "Standard/Admin WH pool present"
  else
    fail "Standard/Admin WH pool missing"
  fi

  if grep -qi 'token\|/snowflake/session/token\|SPCS' "$BE_DIR/snowflake_client.py"; then
    pass "SPCS token auth present"
  else
    fail "SPCS token auth missing"
  fi

  if grep -qi 'key.*pair\|private_key' "$BE_DIR/snowflake_client.py"; then
    pass "Key-pair auth fallback present"
  else
    fail "Key-pair auth fallback missing"
  fi

  if grep -qi 'health\|ping\|check' "$BE_DIR/snowflake_client.py"; then
    pass "Health check present"
  else
    fail "Health check missing"
  fi

  if grep -qi 'execute\|query\|run_query' "$BE_DIR/snowflake_client.py"; then
    pass "Query execution helper present"
  else
    fail "Query execution helper missing"
  fi
else
  fail "snowflake_client.py does not exist"
  for item in "Interactive WH pool" "Standard/Admin WH pool" "SPCS token auth" "Key-pair auth fallback" "Health check" "Query execution helper"; do
    fail "$item missing (file not found)"
  done
fi

# =============================================================================
# Issue #12: SQL query templates
# =============================================================================

echo ""
echo "--- Issue #12: SQL Query Templates ---"
echo ""

QUERIES_DIR="$BE_DIR/queries"

TEMPLATES=(summary timeseries breakdown events latency filters)

for tmpl in "${TEMPLATES[@]}"; do
  echo "[3] queries/$tmpl.sql"
  if [ -f "$QUERIES_DIR/$tmpl.sql" ]; then
    pass "$tmpl.sql exists"
  else
    fail "$tmpl.sql missing"
  fi
done

# Summary query specifics
if [ -f "$QUERIES_DIR/summary.sql" ]; then
  if grep -qi 'IT_AUTH_MINUTE_METRICS' "$QUERIES_DIR/summary.sql"; then
    pass "summary.sql queries IT_AUTH_MINUTE_METRICS"
  else
    fail "summary.sql does not query IT_AUTH_MINUTE_METRICS"
  fi

  if grep -qi 'SUM.*latency_sum_ms.*SUM.*latency_count\|latency_sum_ms.*latency_count' "$QUERIES_DIR/summary.sql"; then
    pass "summary.sql uses weighted avg latency"
  else
    fail "summary.sql missing weighted avg latency"
  fi
fi

# Breakdown query
if [ -f "$QUERIES_DIR/breakdown.sql" ]; then
  if grep -qi 'LIMIT\|limit' "$QUERIES_DIR/breakdown.sql"; then
    pass "breakdown.sql has LIMIT"
  else
    fail "breakdown.sql missing LIMIT"
  fi
fi

# Events query
if [ -f "$QUERIES_DIR/events.sql" ]; then
  if grep -qi 'IT_AUTH_EVENT_SEARCH' "$QUERIES_DIR/events.sql"; then
    pass "events.sql queries IT_AUTH_EVENT_SEARCH"
  else
    fail "events.sql does not query IT_AUTH_EVENT_SEARCH"
  fi
fi

# Latency query
if [ -f "$QUERIES_DIR/latency.sql" ]; then
  if grep -qi 'PERCENTILE_CONT' "$QUERIES_DIR/latency.sql"; then
    pass "latency.sql uses PERCENTILE_CONT"
  else
    fail "latency.sql missing PERCENTILE_CONT"
  fi
fi

# =============================================================================
# Issue #13: Route handlers and Pydantic models
# =============================================================================

echo ""
echo "--- Issue #13: Route Handlers ---"
echo ""

ROUTES_DIR="$BE_DIR/routes"

echo "[4] Route files"
for route in summary timeseries breakdown events filters; do
  if [ -f "$ROUTES_DIR/$route.py" ]; then
    pass "routes/$route.py exists"
  else
    fail "routes/$route.py missing"
  fi
done

echo "[5] app/backend/main.py"
if [ -f "$BE_DIR/main.py" ]; then
  pass "main.py exists"

  if grep -qi 'FastAPI\|fastapi' "$BE_DIR/main.py"; then
    pass "FastAPI app present"
  else
    fail "FastAPI app missing"
  fi

  if grep -qi '/health' "$BE_DIR/main.py"; then
    pass "/health endpoint present"
  else
    fail "/health endpoint missing"
  fi

  if grep -qi 'CORS\|CORSMiddleware' "$BE_DIR/main.py"; then
    pass "CORS middleware present"
  else
    fail "CORS middleware missing"
  fi

  if grep -qi 'static\|StaticFiles\|mount' "$BE_DIR/main.py"; then
    pass "Static file serving present"
  else
    fail "Static file serving missing"
  fi
else
  fail "main.py does not exist"
  for item in "FastAPI app" "/health endpoint" "CORS middleware" "Static file serving"; do
    fail "$item missing (file not found)"
  done
fi

# Pydantic models
echo "[6] Pydantic models"
if grep -rqi 'BaseModel\|pydantic' "$ROUTES_DIR"/*.py "$BE_DIR/main.py" 2>/dev/null; then
  pass "Pydantic models used in routes"
else
  fail "Pydantic models not found in routes"
fi

# =============================================================================
# Issue #14: Latency endpoint and freshness logic
# =============================================================================

echo ""
echo "--- Issue #14: Latency and Freshness ---"
echo ""

echo "[7] routes/latency.py"
if [ -f "$ROUTES_DIR/latency.py" ]; then
  pass "routes/latency.py exists"

  if grep -qi 'histogram\|bucket' "$ROUTES_DIR/latency.py"; then
    pass "Histogram logic present"
  else
    fail "Histogram logic missing"
  fi

  if grep -qi 'percentile\|p50\|p95\|p99' "$ROUTES_DIR/latency.py"; then
    pass "Percentile logic present"
  else
    fail "Percentile logic missing"
  fi

  if grep -qi 'max_limit\|limit' "$ROUTES_DIR/latency.py"; then
    pass "max_limit parameter present"
  else
    fail "max_limit parameter missing"
  fi
else
  fail "routes/latency.py does not exist"
  fail "Histogram logic missing (file not found)"
  fail "Percentile logic missing (file not found)"
  fail "max_limit parameter missing (file not found)"
fi

echo "[8] Freshness logic"
if grep -rqi 'freshness\|ingested_at\|MAX.*ingested' "$ROUTES_DIR"/*.py "$QUERIES_DIR"/*.sql 2>/dev/null; then
  pass "Freshness logic present"
else
  fail "Freshness logic not found"
fi

if grep -rqi 'RAW\|standard.*wh\|admin.*wh' "$ROUTES_DIR"/*.py "$BE_DIR/snowflake_client.py" 2>/dev/null; then
  pass "Freshness routes to standard warehouse"
else
  fail "Freshness warehouse routing not found"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
