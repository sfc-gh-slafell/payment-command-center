#!/usr/bin/env bash
# tests/validate_frontend.sh
# TDD validation for frontend code
#
# Issue #16: Project scaffold, Tailwind, API types
# Issue #17: FilterBar and KPIStrip
# Issue #18: TimeSeriesChart
# Issue #19: BreakdownTable and RecentFailures
# Issue #20: CompareMode, LatencyPanel, FreshnessWidget
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
FE_DIR="$PROJECT_DIR/app/frontend"
SRC_DIR="$FE_DIR/src"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "=== Frontend Validation Tests ==="
echo ""

# =============================================================================
# Issue #16: Project scaffold
# =============================================================================

echo "--- Issue #16: Frontend Scaffold ---"
echo ""

echo "[1] Project structure"
if [ -f "$FE_DIR/package.json" ]; then
  pass "package.json exists"
  for dep in react recharts @tanstack/react-query tailwindcss date-fns; do
    if grep -q "$dep" "$FE_DIR/package.json"; then
      pass "Dependency $dep listed"
    else
      fail "Dependency $dep missing"
    fi
  done
else
  fail "package.json does not exist"
  for dep in react recharts @tanstack/react-query tailwindcss date-fns; do
    fail "Dependency $dep missing (file not found)"
  done
fi

if [ -f "$FE_DIR/vite.config.ts" ] || [ -f "$FE_DIR/vite.config.js" ]; then
  pass "Vite config exists"
else
  fail "Vite config missing"
fi

if [ -f "$FE_DIR/tsconfig.json" ]; then
  pass "tsconfig.json exists"
else
  fail "tsconfig.json missing"
fi

echo "[2] API types"
if [ -f "$SRC_DIR/types/api.ts" ]; then
  pass "types/api.ts exists"
  for iface in SummaryResponse TimeseriesResponse BreakdownResponse EventsResponse LatencyResponse FiltersResponse; do
    if grep -q "$iface" "$SRC_DIR/types/api.ts"; then
      pass "Interface $iface defined"
    else
      fail "Interface $iface missing"
    fi
  done
else
  fail "types/api.ts does not exist"
  for iface in SummaryResponse TimeseriesResponse BreakdownResponse EventsResponse LatencyResponse FiltersResponse; do
    fail "Interface $iface missing (file not found)"
  done
fi

echo "[3] useApiQuery hook"
if [ -f "$SRC_DIR/hooks/useApiQuery.ts" ]; then
  pass "useApiQuery.ts exists"
  if grep -qi '15.*000\|15000\|refetchInterval' "$SRC_DIR/hooks/useApiQuery.ts"; then
    pass "15-second polling configured"
  else
    fail "15-second polling not configured"
  fi
else
  fail "useApiQuery.ts does not exist"
  fail "15-second polling not configured (file not found)"
fi

echo "[4] App.tsx"
if [ -f "$SRC_DIR/App.tsx" ]; then
  pass "App.tsx exists"
  if grep -qi 'filter\|Filter' "$SRC_DIR/App.tsx"; then
    pass "Filter section in layout"
  else
    fail "Filter section not in layout"
  fi
  if grep -qi 'grid\|Grid\|layout\|Layout' "$SRC_DIR/App.tsx"; then
    pass "Grid/layout structure present"
  else
    fail "Grid/layout structure missing"
  fi
else
  fail "App.tsx does not exist"
  fail "Filter section not in layout (file not found)"
  fail "Grid/layout structure missing (file not found)"
fi

echo "[5] Tailwind config"
if [ -f "$FE_DIR/tailwind.config.js" ] || [ -f "$FE_DIR/tailwind.config.ts" ]; then
  pass "Tailwind config exists"
else
  fail "Tailwind config missing"
fi

# =============================================================================
# Issue #17: FilterBar and KPIStrip
# =============================================================================

echo ""
echo "--- Issue #17: FilterBar and KPIStrip ---"
echo ""

echo "[6] FilterBar.tsx"
if [ -f "$SRC_DIR/components/FilterBar.tsx" ]; then
  pass "FilterBar.tsx exists"
  if grep -qi 'time.*range\|timeRange\|time_range' "$SRC_DIR/components/FilterBar.tsx"; then
    pass "Time range filter present"
  else
    fail "Time range filter missing"
  fi
  if grep -qi 'merchant\|Merchant' "$SRC_DIR/components/FilterBar.tsx"; then
    pass "Merchant filter present"
  else
    fail "Merchant filter missing"
  fi
  if grep -qi 'region\|Region' "$SRC_DIR/components/FilterBar.tsx"; then
    pass "Region filter present"
  else
    fail "Region filter missing"
  fi
else
  fail "FilterBar.tsx does not exist"
  fail "Time range filter missing (file not found)"
  fail "Merchant filter missing (file not found)"
  fail "Region filter missing (file not found)"
fi

echo "[7] KPIStrip.tsx"
if [ -f "$SRC_DIR/components/KPIStrip.tsx" ]; then
  pass "KPIStrip.tsx exists"
  if grep -qi 'approval\|auth.*rate\|approve' "$SRC_DIR/components/KPIStrip.tsx"; then
    pass "Approval rate KPI present"
  else
    fail "Approval rate KPI missing"
  fi
  if grep -qi 'decline\|Decline' "$SRC_DIR/components/KPIStrip.tsx"; then
    pass "Decline rate KPI present"
  else
    fail "Decline rate KPI missing"
  fi
  if grep -qi 'latency\|Latency' "$SRC_DIR/components/KPIStrip.tsx"; then
    pass "Latency KPI present"
  else
    fail "Latency KPI missing"
  fi
  if grep -qi 'delta\|Delta\|change\|Change\|prev' "$SRC_DIR/components/KPIStrip.tsx"; then
    pass "Delta indicator present"
  else
    fail "Delta indicator missing"
  fi
else
  fail "KPIStrip.tsx does not exist"
  for item in "Approval rate KPI" "Decline rate KPI" "Latency KPI" "Delta indicator"; do
    fail "$item missing (file not found)"
  done
fi

# =============================================================================
# Issue #18: TimeSeriesChart
# =============================================================================

echo ""
echo "--- Issue #18: TimeSeriesChart ---"
echo ""

echo "[8] TimeSeriesChart.tsx"
if [ -f "$SRC_DIR/components/TimeSeriesChart.tsx" ]; then
  pass "TimeSeriesChart.tsx exists"
  if grep -qi 'ComposedChart\|composed\|BarChart\|LineChart' "$SRC_DIR/components/TimeSeriesChart.tsx"; then
    pass "Recharts chart component used"
  else
    fail "Recharts chart component missing"
  fi
  if grep -qi 'YAxis\|yAxis' "$SRC_DIR/components/TimeSeriesChart.tsx"; then
    pass "Y-axis configured"
  else
    fail "Y-axis missing"
  fi
  if grep -qi 'Tooltip\|tooltip' "$SRC_DIR/components/TimeSeriesChart.tsx"; then
    pass "Tooltip present"
  else
    fail "Tooltip missing"
  fi
  if grep -qi 'timeseries\|time_series\|time-series' "$SRC_DIR/components/TimeSeriesChart.tsx"; then
    pass "Timeseries data reference"
  else
    fail "Timeseries data reference missing"
  fi
else
  fail "TimeSeriesChart.tsx does not exist"
  for item in "Recharts chart component" "Y-axis" "Tooltip" "Timeseries data reference"; do
    fail "$item missing (file not found)"
  done
fi

# =============================================================================
# Issue #19: BreakdownTable and RecentFailures
# =============================================================================

echo ""
echo "--- Issue #19: BreakdownTable and RecentFailures ---"
echo ""

echo "[9] BreakdownTable.tsx"
if [ -f "$SRC_DIR/components/BreakdownTable.tsx" ]; then
  pass "BreakdownTable.tsx exists"
  if grep -qi 'merchant\|region\|issuer\|card.*brand' "$SRC_DIR/components/BreakdownTable.tsx"; then
    pass "Dimension tabs present"
  else
    fail "Dimension tabs missing"
  fi
  if grep -qi 'sort\|Sort' "$SRC_DIR/components/BreakdownTable.tsx"; then
    pass "Sort functionality present"
  else
    fail "Sort functionality missing"
  fi
else
  fail "BreakdownTable.tsx does not exist"
  fail "Dimension tabs missing (file not found)"
  fail "Sort functionality missing (file not found)"
fi

echo "[10] RecentFailures.tsx"
if [ -f "$SRC_DIR/components/RecentFailures.tsx" ]; then
  pass "RecentFailures.tsx exists"
  if grep -qi 'DECLINED\|declined\|error\|ERROR\|failure' "$SRC_DIR/components/RecentFailures.tsx"; then
    pass "Failure status filter present"
  else
    fail "Failure status filter missing"
  fi
  if grep -qi 'modal\|Modal\|detail\|Detail' "$SRC_DIR/components/RecentFailures.tsx"; then
    pass "Event detail modal present"
  else
    fail "Event detail modal missing"
  fi
else
  fail "RecentFailures.tsx does not exist"
  fail "Failure status filter missing (file not found)"
  fail "Event detail modal missing (file not found)"
fi

# =============================================================================
# Issue #20: CompareMode, LatencyPanel, FreshnessWidget
# =============================================================================

echo ""
echo "--- Issue #20: CompareMode, LatencyPanel, FreshnessWidget ---"
echo ""

echo "[11] CompareMode.tsx"
if [ -f "$SRC_DIR/components/CompareMode.tsx" ]; then
  pass "CompareMode.tsx exists"
  if grep -qi 'current.*prev\|compare\|delta\|side.*by.*side\|vs' "$SRC_DIR/components/CompareMode.tsx"; then
    pass "Comparison logic present"
  else
    fail "Comparison logic missing"
  fi
else
  fail "CompareMode.tsx does not exist"
  fail "Comparison logic missing (file not found)"
fi

echo "[12] LatencyPanel.tsx"
if [ -f "$SRC_DIR/components/LatencyPanel.tsx" ]; then
  pass "LatencyPanel.tsx exists"
  if grep -qi 'histogram\|bucket\|bar' "$SRC_DIR/components/LatencyPanel.tsx"; then
    pass "Histogram display present"
  else
    fail "Histogram display missing"
  fi
  if grep -qi 'p50\|p95\|p99\|percentile' "$SRC_DIR/components/LatencyPanel.tsx"; then
    pass "Percentile stats present"
  else
    fail "Percentile stats missing"
  fi
else
  fail "LatencyPanel.tsx does not exist"
  fail "Histogram display missing (file not found)"
  fail "Percentile stats missing (file not found)"
fi

echo "[13] FreshnessWidget.tsx"
if [ -f "$SRC_DIR/components/FreshnessWidget.tsx" ]; then
  pass "FreshnessWidget.tsx exists"
  if grep -qi 'raw\|Raw\|serving\|Serving\|ago' "$SRC_DIR/components/FreshnessWidget.tsx"; then
    pass "Freshness display present"
  else
    fail "Freshness display missing"
  fi
  if grep -qi 'green\|yellow\|red\|color\|stale' "$SRC_DIR/components/FreshnessWidget.tsx"; then
    pass "Color-coded thresholds present"
  else
    fail "Color-coded thresholds missing"
  fi
else
  fail "FreshnessWidget.tsx does not exist"
  fail "Freshness display missing (file not found)"
  fail "Color-coded thresholds missing (file not found)"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
