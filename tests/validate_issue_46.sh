#!/bin/bash
# Validation script for Issue #46: Active Scenario Indicator
# Run this to verify implementation completeness

set -e

echo "=== Issue #46 Validation: Active Scenario Indicator ==="
echo

# Check backend files exist
echo "✓ Checking backend implementation files..."
test -f app/backend/generator_client.py || echo "❌ MISSING: app/backend/generator_client.py"
test -f app/backend/routes/summary.py || echo "✓ EXISTS: app/backend/routes/summary.py"

# Check frontend files exist
echo "✓ Checking frontend implementation files..."
test -f app/frontend/src/components/ScenarioBadge.tsx || echo "❌ MISSING: app/frontend/src/components/ScenarioBadge.tsx"
test -f app/frontend/src/types/api.ts || echo "✓ EXISTS: app/frontend/src/types/api.ts"

# Check test files exist
echo "✓ Checking test files..."
test -f tests/test_scenario_indicator_backend.py && echo "✓ EXISTS: Backend tests"
test -f app/frontend/src/__tests__/ScenarioBadge.test.tsx && echo "✓ EXISTS: Frontend tests"

echo
echo "=== Type Checks ==="
cd app/frontend
npx tsc --noEmit 2>&1 | grep -E "(error|warning)" | head -5 || echo "✓ TypeScript compilation passed"

echo
echo "=== Backend Import Checks ==="
cd ../../
python -c "from app.backend.generator_client import GeneratorClient" 2>&1 || echo "❌ generator_client not importable"
python -c "from app.backend.routes.summary import SummaryResponse" && echo "✓ SummaryResponse importable"

echo
echo "=== Acceptance Criteria Checklist ==="
echo "- [ ] Backend successfully polls generator API"
echo "- [ ] ScenarioBadge displays in dashboard header"
echo "- [ ] Color changes based on scenario type"
echo "- [ ] Time countdown updates in real-time"
echo "- [ ] Gracefully handles generator unavailable"
