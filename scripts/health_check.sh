#!/usr/bin/env bash
# health_check.sh — Pipeline health checks for the payments demo
#
# Checks:
#   1. Container running/health state
#   2. Host system memory pressure (v4 connector throttle trigger)
#   3. V4 MemoryThresholdExceeded errors in logs (REST API is not sufficient)
#   4. Connector task state via REST API
#   5. Kafka consumer lag (v4 group + optional fallback relay group)
#
# See claudedocs/kafka-memory-throttle.md for full explanation of the
# MemoryThresholdExceeded / HTTP 429 issue.

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0; WARN=0; FAIL=0

ok()   { echo -e "  ${GREEN}[OK]${NC}   $*";   ((PASS++)) || true; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*";  ((WARN++)) || true; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*";     ((FAIL++)) || true; }
header() { echo -e "\n${BOLD}── $* ──${NC}"; }

echo ""
echo -e "${BOLD}=== Pipeline Health Check — $(date) ===${NC}"

# ─────────────────────────────────────────────────────────
# 1. Container status
# ─────────────────────────────────────────────────────────
header "Containers"
for container in payments-kafka payments-kafka-connect payments-generator; do
  state=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "missing")
  health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$container" 2>/dev/null || echo "missing")

  if [[ "$state" != "running" ]]; then
    fail "$container: state=$state"
  elif [[ "$health" == "unhealthy" ]]; then
    fail "$container: running but health=$health"
  elif [[ "$health" == "starting" ]]; then
    warn "$container: running, health=starting (still initialising)"
  else
    ok "$container: running ($health)"
  fi
done

# Fallback relay is optional (profiles: [fallback]) — not running is expected during normal ops
relay_state=$(docker inspect --format='{{.State.Status}}' payments-fallback-relay 2>/dev/null || echo "missing")
if [[ "$relay_state" == "running" ]]; then
  ok "payments-fallback-relay: running (resilience demo active)"
else
  echo -e "  ${YELLOW}[INFO]${NC}  payments-fallback-relay: not running (normal — start with 'make fallback-start' for demo)"
fi

# ─────────────────────────────────────────────────────────
# 2. Host memory pressure
#    The V4 Snowpipe Streaming Rust client reads HOST system
#    memory and refuses appendRow calls when usage >= 90%.
#    This check catches the condition BEFORE the connector stalls.
# ─────────────────────────────────────────────────────────
header "Host Memory (V4 Throttle Risk)"

# macOS: derive used% from vm_stat page counts (4096 bytes/page)
sys_mem_pct=$(vm_stat 2>/dev/null | awk '
  /Pages free:/               { free=$3+0 }
  /Pages active:/             { act=$3+0 }
  /Pages inactive:/           { inact=$3+0 }
  /Pages wired down:/         { wired=$4+0 }
  /Pages occupied by compressor:/ { comp=$5+0 }
  END {
    used  = act + wired + comp
    total = free + act + inact + wired + comp
    if (total > 0) printf "%.0f", (used / total) * 100
    else print "0"
  }' 2>/dev/null || echo "0")

if [[ "$sys_mem_pct" -ge 90 ]]; then
  fail "System memory: ${sys_mem_pct}% used — V4 Snowpipe Streaming IS throttled (threshold: 90%)"
  fail "  → appendRow blocked; connector shows RUNNING but NO data flows to Snowflake"
elif [[ "$sys_mem_pct" -ge 85 ]]; then
  warn "System memory: ${sys_mem_pct}% used — approaching V4 throttle threshold (90%)"
else
  ok "System memory: ${sys_mem_pct}% used"
fi

# ─────────────────────────────────────────────────────────
# 3. V4 MemoryThresholdExceeded errors (last 5 minutes)
#    CRITICAL: REST API shows RUNNING even when data is blocked.
#    Log scanning is the only reliable signal for this failure mode.
# ─────────────────────────────────────────────────────────
header "V4 Memory Throttle Errors (last 5m)"

throttle_count=$(docker logs payments-kafka-connect --since 5m 2>&1 \
  | grep -c "MemoryThresholdExceeded" 2>/dev/null || true)
last_attempt_line=$(docker logs payments-kafka-connect --since 5m 2>&1 \
  | grep "Failed attempt #" | tail -1 2>/dev/null || true)
last_attempt=$(echo "$last_attempt_line" | grep -oE "attempt #[0-9]+" | grep -oE "[0-9]+$" || echo "0")

if [[ "$throttle_count" -gt 0 ]]; then
  fail "MemoryThresholdExceeded: $throttle_count occurrences in last 5m (latest: attempt #${last_attempt})"
  fail "  → appendRow API blocked — data NOT flowing to Snowflake"
  fail "  → See claudedocs/kafka-memory-throttle.md"
else
  ok "No MemoryThresholdExceeded errors in last 5m"
fi

# ─────────────────────────────────────────────────────────
# 4. Connector task state (Kafka Connect REST API)
#    NOTE: RUNNING here does NOT guarantee data is flowing.
#    Check #3 above is the authoritative signal for V4.
# ─────────────────────────────────────────────────────────
header "Connector Task State (REST API)"

check_connector() {
  local url=$1 name=$2 label=$3
  local resp
  resp=$(curl -sf --max-time 5 "${url}/connectors/${name}/status" 2>/dev/null || echo "")
  if [[ -z "$resp" ]]; then
    fail "${label}: REST API unreachable at ${url}"
    return
  fi
  local connector_state failed total
  connector_state=$(echo "$resp" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d['connector']['state'])" 2>/dev/null || echo "UNKNOWN")
  failed=$(echo "$resp" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(sum(1 for t in d['tasks'] if t['state']=='FAILED'))" 2>/dev/null || echo "?")
  total=$(echo "$resp" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(len(d['tasks']))" 2>/dev/null || echo "?")

  if [[ "$connector_state" == "RUNNING" && "$failed" == "0" ]]; then
    ok "${label}: RUNNING, ${total} task(s) healthy (REST only — see check above for data-flow truth)"
  else
    fail "${label}: connector=${connector_state}, failed=${failed}/${total} tasks"
  fi
}

check_connector "http://localhost:8083" "auth-events-sink-v4" "V4 HP connector"

# ─────────────────────────────────────────────────────────
# 5. Kafka consumer lag
#    Growing lag + MemoryThresholdExceeded = confirmed data gap.
# ─────────────────────────────────────────────────────────
header "Consumer Lag"

check_lag() {
  local group=$1 label=$2
  local lag_output total_lag
  lag_output=$(docker exec payments-kafka \
    /opt/kafka/bin/kafka-consumer-groups.sh \
    --bootstrap-server kafka:29092 \
    --describe --group "$group" 2>/dev/null | tail -n +2 || echo "")

  if [[ -z "$lag_output" ]]; then
    warn "${label}: could not fetch lag"
    return
  fi

  total_lag=$(echo "$lag_output" | awk 'NF>0 && $6~/^[0-9]+$/ {sum += $6} END {print sum+0}')

  if   [[ "$total_lag" -gt 5000000 ]]; then
    fail  "${label}: lag=${total_lag} — severe backlog, data gap growing"
  elif [[ "$total_lag" -gt 500000 ]]; then
    warn "${label}: lag=${total_lag} — backlog building"
  else
    ok   "${label}: lag=${total_lag}"
  fi
}

check_lag "snowflake-connector-group" "V4 HP  (payments.auth)"

# Fallback relay group — only report lag if the container is actually running
if [[ "$relay_state" == "running" ]]; then
  check_lag "snowflake-fallback-relay" "Fallback relay (payments.auth)"
else
  echo -e "  ${YELLOW}[INFO]${NC}  Fallback relay: not running — skipping lag check"
fi

# ─────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Summary ──${NC}"
echo -e "  ${GREEN}OK:${NC}   $PASS"
echo -e "  ${YELLOW}WARN:${NC} $WARN"
echo -e "  ${RED}FAIL:${NC} $FAIL"
echo ""

if   [[ "$FAIL" -gt 0 ]]; then exit 1
elif [[ "$WARN" -gt 0 ]]; then exit 2
fi
