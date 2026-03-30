# Payment Command Center — Demo Runbook

Operator guide for running the Payment Command Center live demonstration.

---

## Pre-Demo Checklist

Run through this checklist at least **1 hour before** the demo begins.

### Snowflake Objects

```sql
-- Verify database and schemas exist
SHOW DATABASES LIKE 'PAYMENTS_DB';
SHOW SCHEMAS IN DATABASE PAYMENTS_DB;

-- Verify interactive tables exist
SHOW DYNAMIC TABLES IN SCHEMA PAYMENTS_DB.SERVE;

-- Verify warehouses are available
SHOW WAREHOUSES LIKE 'PAYMENTS%';
```

- [ ] `PAYMENTS_DB` database exists
- [ ] Schemas: RAW, SERVE, CURATED, APP
- [ ] Interactive tables: `IT_AUTH_MINUTE_METRICS`, `IT_AUTH_EVENT_SEARCH`
- [ ] Warehouses: `PAYMENTS_INTERACTIVE_WH`, `PAYMENTS_ADMIN_WH`, `PAYMENTS_REFRESH_WH`

### Event Generator

```bash
# Check generator status
curl http://localhost:8000/status
# Expected: {"scenario":"baseline","events_per_sec":500,...}
```

- [ ] Generator is running and producing events
- [ ] Confirm events flowing into `AUTH_EVENTS_RAW`

### SPCS Service Health

```sql
-- Check SPCS service status
SELECT SYSTEM$GET_SERVICE_STATUS('PAYMENTS_DB.APP.PAYMENT_COMMAND_CENTER');
```

- [ ] Service status = `READY`
- [ ] Dashboard loads at service public endpoint

### HP Connector Status

```bash
curl http://<kafka-connect>:8083/connectors/auth-events-sink-payments/status
# Expected: {"connector":{"state":"RUNNING"},"tasks":[{"state":"RUNNING",...}]}
```

- [ ] HP connector status = `RUNNING`
- [ ] All 24 tasks running

### Dashboard Final Check

- [ ] Dashboard loads and shows data in all panels
- [ ] KPI strip shows current values (not --/--)
- [ ] Time series chart has data points
- [ ] FreshnessWidget shows green/yellow (not red)

---

## Warehouse Warm-Up

**Start warm-up at least 1 hour before the demo.**

Interactive warehouses need the cache populated before the first demo query — cold cache = slow first response.

```sql
-- 1. Resume the interactive warehouse
ALTER WAREHOUSE PAYMENTS_INTERACTIVE_WH RESUME;

-- 2. Warm up IT_AUTH_MINUTE_METRICS
SELECT COUNT(*),
       SUM(event_count),
       SUM(latency_sum_ms) / NULLIF(SUM(latency_count), 0) AS avg_latency_ms
FROM PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS
WHERE event_minute >= DATEADD('HOUR', -2, CURRENT_TIMESTAMP());

-- Repeat a few times to populate cache layers
SELECT merchant_id,
       SUM(event_count) AS events,
       SUM(decline_count) * 100.0 / NULLIF(SUM(event_count), 0) AS decline_rate
FROM PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS
WHERE event_minute >= DATEADD('MINUTE', -30, CURRENT_TIMESTAMP())
GROUP BY merchant_id
ORDER BY events DESC;

-- 3. Warm up IT_AUTH_EVENT_SEARCH
SELECT COUNT(*), MAX(event_ts)
FROM PAYMENTS_DB.SERVE.IT_AUTH_EVENT_SEARCH
WHERE event_ts >= DATEADD('MINUTE', -15, CURRENT_TIMESTAMP());
```

> **Note**: Interactive warehouse `AUTO_SUSPEND=86400` (24h) — it will stay up through the demo once resumed.

---

## Scenario Playbook

### Recommended Demo Flow

```
1. Baseline (show steady state, explain the dashboard)
2. issuer_outage (dramatic decline spike — good for impact demo)
3. Return to baseline (watch recovery)
4. latency_spike (EU latency spike — good for latency panel)
5. Return to baseline
```

### 1. Baseline (steady state)

This is the default. No curl needed — restart via DELETE if in another scenario.

Expected dashboard behavior:
- Auth Rate ~95%, Decline Rate ~5%
- Avg latency 50-150ms
- FreshnessWidget: green on both Raw and Serving

---

### 2. Issuer Outage (BIN 4111xx drops to 10% approval)

```bash
# Activate issuer outage scenario for 5 minutes
curl -X POST http://localhost:8000/scenario \
  -H "Content-Type: application/json" \
  -d '{"profile": "issuer_outage", "duration_sec": 300}'
```

Expected dashboard behavior (allow **60-90 seconds** for serving layer to refresh):
- Decline Rate spikes to ~40-50% (BINs 411111, 424242)
- ISSUER_UNAVAILABLE appears in Recent Failures
- KPI strip decline rate turns red
- Breakdown table shows VISA cards leading decline rate

```bash
# Return to baseline manually (or let duration expire)
curl -X DELETE http://localhost:8000/scenario
```

---

### 3. Merchant Decline Spike (TechBazaar M0003 — 60% decline)

```bash
# Activate merchant decline spike for 5 minutes
curl -X POST http://localhost:8000/scenario \
  -H "Content-Type: application/json" \
  -d '{"profile": "merchant_decline_spike", "duration_sec": 300}'
```

Expected dashboard behavior:
- M0003 (TechBazaar) appears at top of Breakdown table with ~60% decline rate
- DO_NOT_HONOR fills Recent Failures
- Compare mode shows dramatic delta for M0003

---

### 4. Latency Spike (EU region 800-2000ms)

```bash
# Activate EU latency spike for 5 minutes
curl -X POST http://localhost:8000/scenario \
  -H "Content-Type: application/json" \
  -d '{"profile": "latency_spike", "duration_sec": 300}'
```

Expected dashboard behavior:
- Latency panel histogram shifts right (>500ms and >1s buckets fill)
- p95/p99 climb dramatically
- EU region leads in Breakdown table by avg latency
- Avg Latency KPI turns red

---

### Adjust Event Rate

```bash
# Ramp up to peak load
curl -X POST http://localhost:8000/rate \
  -H "Content-Type: application/json" \
  -d '{"events_per_sec": 2000}'

# Return to baseline rate
curl -X POST http://localhost:8000/rate \
  -H "Content-Type: application/json" \
  -d '{"events_per_sec": 500}'
```

---

## Troubleshooting

### Cold Cache (queries slow, dashboard loads slowly)

Re-run warm-up queries from the [Warehouse Warm-Up](#warehouse-warm-up) section. Allow 5-10 minutes for queries to fully warm the cache.

### HP Connector Down (fallback cutover)

```bash
# 1. Check connector status
curl http://<kafka-connect>:8083/connectors/auth-events-sink-payments/status

# 2. If FAILED, pause and note consumer group lag
curl -X PUT http://<kafka-connect>:8083/connectors/auth-events-sink-payments/pause

# 3. Start fallback relay (separate terminal/pod)
# Set env vars: KAFKA_BOOTSTRAP_SERVERS, SNOWFLAKE_ACCOUNT, etc.
docker run -d \
  -e KAFKA_BOOTSTRAP_SERVERS=<broker>:9092 \
  -e SNOWFLAKE_ACCOUNT=$SNOWFLAKE_ACCOUNT \
  -e SNOWFLAKE_USER=$SNOWFLAKE_USER \
  -e SNOWFLAKE_PRIVATE_KEY_PATH=/run/secrets/snowflake_key.p8 \
  fallback-relay:latest

# Note: fallback uses group 'snowflake-fallback-relay' — no conflict
# Latency increases from ~10s to ~1-3 minutes
```

To switch back to HP connector:
```bash
# Stop relay, resume connector
docker stop <relay-container>
curl -X PUT http://<kafka-connect>:8083/connectors/auth-events-sink-payments/resume
```

### Stale Interactive Tables (data not refreshing)

```sql
-- Check dynamic table refresh history
SELECT
    name,
    state,
    refresh_start_time,
    refresh_end_time,
    error_message
FROM TABLE(PAYMENTS_DB.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY())
WHERE name IN ('IT_AUTH_MINUTE_METRICS', 'IT_AUTH_EVENT_SEARCH')
ORDER BY refresh_start_time DESC
LIMIT 10;
```

If refresh is failing:
1. Check warehouse `PAYMENTS_REFRESH_WH` is running
2. Verify `PAYMENTS_INGEST_ROLE` has SELECT on `AUTH_EVENTS_RAW`
3. Manually trigger: `ALTER DYNAMIC TABLE PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS REFRESH`

### SPCS Service Unhealthy

```sql
-- Check SPCS service status
SELECT SYSTEM$GET_SERVICE_STATUS('PAYMENTS_DB.APP.PAYMENT_COMMAND_CENTER');

-- Check service logs
SELECT value FROM TABLE(
  SYSTEM$GET_SERVICE_LOGS('PAYMENTS_DB.APP.PAYMENT_COMMAND_CENTER', 0, 'dashboard', 100)
);
```

If unhealthy:
```sql
-- Restart service
ALTER SERVICE PAYMENTS_DB.APP.PAYMENT_COMMAND_CENTER SUSPEND;
ALTER SERVICE PAYMENTS_DB.APP.PAYMENT_COMMAND_CENTER RESUME;
```

---

## Post-Demo Cleanup

```bash
# Stop event generator
curl -X DELETE http://localhost:8000/scenario  # Return to baseline first
# Then stop generator process

# Suspend warehouses to save credits
# (PAYMENTS_INTERACTIVE_WH auto-suspends after 24h if not queried)
```

```sql
-- Optional: suspend warehouses immediately
ALTER WAREHOUSE PAYMENTS_INTERACTIVE_WH SUSPEND;
ALTER WAREHOUSE PAYMENTS_REFRESH_WH SUSPEND;
```

---

## Key Metrics for Demo Narrative

| Metric | Baseline | Issuer Outage | Latency Spike |
|--------|----------|---------------|---------------|
| Approval Rate | ~95% | ~55-60% | ~95% |
| Decline Rate | ~5% | ~40-45% | ~5% |
| Avg Latency | 50-150ms | 50-150ms | 200-800ms |
| p95 Latency | ~200ms | ~200ms | ~1500ms |
| Raw freshness | seconds | seconds | seconds |
| Serving freshness | <60s | <60s | <60s |
