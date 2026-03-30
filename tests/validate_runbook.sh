#!/usr/bin/env bash
# tests/validate_runbook.sh
# TDD validation for demo runbook
#
# Issue #28: Demo runbook and warm-up playbook
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
RUNBOOK="$PROJECT_DIR/docs/RUNBOOK.md"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "=== Runbook Validation Tests ==="
echo ""

echo "[1] docs/RUNBOOK.md"

if [ -f "$RUNBOOK" ]; then
  pass "RUNBOOK.md exists"

  # Pre-demo checklist
  if grep -qi 'pre.*demo\|checklist\|before.*demo' "$RUNBOOK"; then
    pass "Pre-demo checklist section present"
  else
    fail "Pre-demo checklist section missing"
  fi

  # Warm-up section
  if grep -qi 'warm.*up\|warmup\|warm_up' "$RUNBOOK"; then
    pass "Warehouse warm-up section present"
  else
    fail "Warehouse warm-up section missing"
  fi

  # Interactive WH mention
  if grep -qi 'PAYMENTS_INTERACTIVE_WH\|interactive.*wh' "$RUNBOOK"; then
    pass "Interactive WH warm-up documented"
  else
    fail "Interactive WH warm-up missing"
  fi

  # Scenario playbook
  if grep -qi 'scenario\|Scenario\|playbook' "$RUNBOOK"; then
    pass "Scenario playbook section present"
  else
    fail "Scenario playbook section missing"
  fi

  # Curl commands
  if grep -qi 'curl' "$RUNBOOK"; then
    pass "curl commands present"
  else
    fail "curl commands missing"
  fi

  # Troubleshooting section
  if grep -qi 'troubleshoot\|Troubleshoot' "$RUNBOOK"; then
    pass "Troubleshooting section present"
  else
    fail "Troubleshooting section missing"
  fi

  # Fallback procedures
  if grep -qi 'fallback\|Fallback\|relay\|cutover' "$RUNBOOK"; then
    pass "Fallback procedures present"
  else
    fail "Fallback procedures missing"
  fi

  # Scenarios by name
  for scenario in baseline issuer_outage latency_spike merchant_decline_spike; do
    if grep -qi "$scenario" "$RUNBOOK"; then
      pass "Scenario $scenario documented"
    else
      fail "Scenario $scenario missing"
    fi
  done

  # Dynamic table troubleshooting
  if grep -qi 'DYNAMIC_TABLE_REFRESH_HISTORY\|dynamic.*table\|refresh' "$RUNBOOK"; then
    pass "Dynamic table troubleshooting documented"
  else
    fail "Dynamic table troubleshooting missing"
  fi

  # SPCS health check
  if grep -qi 'SYSTEM\$GET_SERVICE_STATUS\|service_status\|spcs.*health\|health.*spcs' "$RUNBOOK"; then
    pass "SPCS health check documented"
  else
    fail "SPCS health check missing"
  fi
else
  fail "RUNBOOK.md does not exist"
  for item in "Pre-demo checklist" "Warm-up section" "Interactive WH" "Scenario playbook" "curl commands" "Troubleshooting" "Fallback" "baseline" "issuer_outage" "latency_spike" "merchant_decline_spike" "Dynamic table" "SPCS health"; do
    fail "$item missing (file not found)"
  done
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
