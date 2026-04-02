---
name: kafka-connect-snowflake
description: Snowflake HP Kafka Connector v4.x configuration for Snowpipe Streaming. Use this skill when configuring Kafka Connect with Snowflake, debugging connector class mismatches, troubleshooting missing data in Snowflake tables from Kafka topics, configuring metadata columns (topic/partition/offset), or creating user-defined pipes for HP connector.
---

# Snowflake HP Kafka Connector

## Purpose

Encode critical configuration patterns for Snowflake HP (High Performance) Kafka Connector v4.x to prevent connector class mismatches, metadata extraction failures, and zero-data landings from silent config errors.

## Critical Rules

### Connector Class (v4.x vs v3.x)

**The #1 cause of silent data loss:** Using the wrong connector class.

```json
// WRONG — v3.x legacy batch connector
{
  "connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector"
}

// CORRECT — HP v4.x streaming connector
{
  "connector.class": "com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector"
}
```

**Symptom of wrong class:** Connector shows as `RUNNING` in Kafka Connect, but 0 rows land in Snowflake. No errors in connector logs. The legacy class operates in Snowpipe batch mode which requires different privileges and object types (stages, pipes with stage paths) not present in streaming-only setups.

### Configuration Key Differences (v3.x vs v4.x)

HP connector v4.x changed several config keys from v3.x. Using v3.x keys causes silent config ignoring or startup errors:

| v3.x Key (WRONG in v4.x) | v4.x Key (CORRECT) | Notes |
|---|---|---|
| `snowflake.ingestion.method` | **REMOVED** | v4.x only supports Snowpipe Streaming HPA — no key needed |
| `snowflake.metadata.offsetAndPartition` | `snowflake.metadata.offset.and.partition` | CamelCase → dot.separated |

**Common mistake:** Carrying forward v3.x config to v4.x without updating keys.

```json
// WRONG — v3.x keys in v4.x connector
{
  "connector.class": "com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector",
  "snowflake.ingestion.method": "SNOWPIPE_STREAMING",  // Unrecognized in v4.x
  "snowflake.metadata.offsetAndPartition": "true"      // Silently ignored
}

// CORRECT — v4.x keys only
{
  "connector.class": "com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector",
  "snowflake.metadata.offset.and.partition": "true"
}
```

### Metadata Column Extraction Pattern

To capture Kafka metadata (topic, partition, offset) in Snowflake columns, you need:

1. **Enable metadata in connector config:**
```json
{
  "snowflake.metadata.offset.and.partition": "true",
  "snowflake.metadata.createtime": "true"
}
```

2. **Define columns in destination table:**
```sql
CREATE TABLE AUTH_EVENTS_RAW (
    -- Business columns
    EVENT_ID VARCHAR(64),
    PAYMENT_ID VARCHAR(64),
    -- Metadata columns for Kafka provenance
    SOURCE_TOPIC VARCHAR(128),
    SOURCE_PARTITION NUMBER,
    SOURCE_OFFSET NUMBER,
    INGESTED_AT TIMESTAMP_NTZ NOT NULL
);
```

3. **Create user-defined pipe to extract metadata from RECORD_METADATA:**

Without a user-defined pipe, the connector auto-generates one that only maps top-level JSON keys to columns. `RECORD_METADATA` (containing topic/partition/offset) is connector-injected and not part of the message JSON, so auto-generated pipes can't access it.

```sql
-- Pipe name MUST match destination table name to trigger user-defined mode
CREATE OR REPLACE PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW AS
COPY INTO PAYMENTS_DB.RAW.AUTH_EVENTS_RAW (
    EVENT_ID, PAYMENT_ID, SOURCE_TOPIC, SOURCE_PARTITION, SOURCE_OFFSET, INGESTED_AT
)
FROM (
    SELECT
        $1:event_id::VARCHAR(64),
        $1:payment_id::VARCHAR(64),
        $1:RECORD_METADATA:topic::VARCHAR(128),       -- From connector metadata
        $1:RECORD_METADATA:partition::NUMBER,         -- From connector metadata
        $1:RECORD_METADATA:offset::NUMBER,            -- From connector metadata
        CURRENT_TIMESTAMP()                           -- For NOT NULL constraint
    FROM TABLE(DATA_SOURCE(TYPE => 'STREAMING'))     -- Required for HP connector
);
```

**Critical details:**
- Pipe name = table name triggers user-defined pipe mode
- `DATA_SOURCE(TYPE => 'STREAMING')` is the FROM clause (not a stage path)
- `$1:RECORD_METADATA:*` accesses connector-injected metadata
- `CURRENT_TIMESTAMP()` for columns with `NOT NULL DEFAULT CURRENT_TIMESTAMP()` — default expressions don't apply in COPY INTO

### Required Grants for Connector Role

```sql
-- Database and schema access
GRANT USAGE ON DATABASE PAYMENTS_DB TO ROLE PAYMENTS_INGEST_ROLE;
GRANT USAGE ON SCHEMA PAYMENTS_DB.RAW TO ROLE PAYMENTS_INGEST_ROLE;

-- Table access (both INSERT and SELECT required)
GRANT INSERT ON TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;
GRANT SELECT ON TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;

-- Pipe access (if using user-defined pipe)
GRANT OPERATE ON PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;

-- CRITICAL: OPERATE is required (not just MONITOR) for HP connector v4.x
-- The connector accesses pipes via Snowpipe Streaming API, which requires OPERATE privilege
-- Without OPERATE, connector fails with ERR_PIPE_DOES_NOT_EXIST_OR_NOT_AUTHORIZED

-- NOTE: USAGE is NOT a valid privilege for PIPE objects
-- Valid pipe privileges: MONITOR (read metadata), OPERATE (ingestion/pause/resume), OWNERSHIP
```

## Configuration with Environment Variables (Secure)

**Critical:** Never hardcode credentials in connector configs. Use Kafka Connect's ConfigProvider for environment variable substitution.

### Enable ConfigProvider in docker-compose.yml

```yaml
services:
  kafka-connect:
    environment:
      # ... other CONNECT_ vars ...
      # Snowflake credentials from .env file
      SNOWFLAKE_URL: "${SNOWFLAKE_URL}"
      SNOWFLAKE_USER: "${SNOWFLAKE_USER}"
      SNOWFLAKE_PRIVATE_KEY: "${SNOWFLAKE_PRIVATE_KEY}"
      # Enable environment variable substitution in connector configs
      CONNECT_CONFIG_PROVIDERS: "env"
      CONNECT_CONFIG_PROVIDERS_ENV_CLASS: "org.apache.kafka.common.config.provider.EnvVarConfigProvider"
```

### Use ${env:} Syntax in Connector Config

```json
{
  "name": "auth-events-sink-payments",
  "config": {
    "connector.class": "com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector",
    "snowflake.url.name": "${env:SNOWFLAKE_URL}",
    "snowflake.user.name": "${env:SNOWFLAKE_USER}",
    "snowflake.private.key": "${env:SNOWFLAKE_PRIVATE_KEY}",
    ...
  }
}
```

**Security verification:**
```bash
# Config should show placeholder, NOT actual key
curl -s http://localhost:8083/connectors/auth-events-sink-payments/config | jq -r '."snowflake.private.key"'
# Output: ${env:SNOWFLAKE_PRIVATE_KEY}
```

**Important:** After adding ConfigProvider settings, you must **recreate the container** (not just restart):
```bash
docker-compose stop kafka-connect
docker-compose rm -f kafka-connect
docker-compose up -d kafka-connect
```

### Connector Configuration Template

```json
{
  "name": "auth-events-snowflake-sink",
  "config": {
    "connector.class": "com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector",
    "tasks.max": "1",

    "topics": "auth-events",

    "snowflake.url.name": "ORGNAME-ACCOUNTNAME.snowflakecomputing.com",
    "snowflake.user.name": "SVC_USER",
    "snowflake.private.key": "MIIEvgIBADANBgkqhkiG9w0BAQE...",
    "snowflake.role.name": "PAYMENTS_INGEST_ROLE",

    "snowflake.database.name": "PAYMENTS_DB",
    "snowflake.schema.name": "RAW",

    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",

    "snowflake.metadata.offset.and.partition": "true",
    "snowflake.metadata.createtime": "true",

    "errors.tolerance": "none",
    "errors.log.enable": "true"
  }
}
```

**Key points:**
- No `snowflake.ingestion.method` key (v4.x only supports streaming)
- Use dot-separated metadata keys (`offset.and.partition`, not `offsetAndPartition`)
- `private.key` is full PKCS8 PEM content (newlines preserved or escaped)
- `errors.tolerance: "none"` fails fast on data issues (prefer for initial setup)

## Installing v4.x HP Connector

### Via Confluent Hub (Stable Versions Only)

```dockerfile
FROM confluentinc/cp-kafka-connect:7.6.0
RUN confluent-hub install --no-prompt snowflakeinc/snowflake-kafka-connector:2.3.0
```

**Issue:** Confluent Hub only has v3.x stable releases. v4.x RC versions are not available.

### Via Maven Central (RC Versions)

For v4.x RC releases, download directly from Maven Central:

```dockerfile
FROM confluentinc/cp-kafka-connect:7.6.0

# Install Snowflake Kafka Connector v4.0.0-rc9 from Maven Central
# Requires Bouncy Castle FIPS cryptography libraries (not regular BC)
RUN mkdir -p /usr/share/confluent-hub-components/snowflakeinc-snowflake-kafka-connector && \
    cd /usr/share/confluent-hub-components/snowflakeinc-snowflake-kafka-connector && \
    curl -sLO https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/4.0.0-rc9/snowflake-kafka-connector-4.0.0-rc9.jar && \
    curl -sLO https://repo1.maven.org/maven2/org/bouncycastle/bc-fips/1.0.2.5/bc-fips-1.0.2.5.jar && \
    curl -sLO https://repo1.maven.org/maven2/org/bouncycastle/bcpkix-fips/1.0.7/bcpkix-fips-1.0.7.jar
```

**Critical:** v4.0.0-rc9 requires **Bouncy Castle FIPS** jars (`bc-fips` + `bcpkix-fips`), NOT regular Bouncy Castle (`bcprov` + `bcpkix`).

**Error if regular BC used:**
```
java.lang.NoClassDefFoundError: org/bouncycastle/jcajce/provider/BouncyCastleFipsProvider
```

**Error if BC jars missing:**
```
java.lang.ClassNotFoundException: org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider
```

### Verify Installation

```bash
# Check installed connector version and class
curl -s http://localhost:8083/connector-plugins | jq '.[] | select(.class | contains("Snowflake"))'

# Expected output for v4.x:
# {
#   "class": "com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector",
#   "version": "4.0.0-rc8"
# }
```

## Common Pitfalls

1. **Zero rows in Snowflake, connector RUNNING** — Using v3.x `SnowflakeSinkConnector` class instead of v4.x `SnowflakeStreamingSinkConnector`.
2. **Metadata columns are NULL** — Wrong metadata config key (camelCase instead of dot.separated) OR missing user-defined pipe to extract `RECORD_METADATA`.
3. **"Unknown configuration key" warnings** — v3.x-only keys like `snowflake.ingestion.method` present in v4.x config. Remove them.
4. **NOT NULL constraint violations on INGESTED_AT** — User-defined pipe must explicitly select `CURRENT_TIMESTAMP()` — default expressions in DDL don't apply to COPY INTO.
5. **CREATE PIPE fails with privilege error** — Pipe must be created by a role with OWNERSHIP on the schema or explicit `CREATE PIPE` privilege.
6. **"GRANT USAGE ON PIPE failed"** — `USAGE` is not a valid privilege for pipes. Use `MONITOR` for read-only access to pipe metadata.
7. **`NoClassDefFoundError: BouncyCastleFipsProvider`** — Using regular Bouncy Castle jars instead of FIPS versions. v4.x requires `bc-fips` and `bcpkix-fips`, not `bcprov` and `bcpkix`.
8. **v3.5.3 installed when v4.x expected** — Confluent Hub `:latest` may resolve to v3.x. Pin version explicitly or download from Maven Central for RC versions.
9. **`${env:SNOWFLAKE_URL}` not resolved** — Environment variable substitution syntax not working in connector config. Use hardcoded values or ensure Kafka Connect is configured to resolve placeholders.
10. **Connector config accepted but fails on start** — Missing Bouncy Castle dependencies only discovered at runtime (connector validation passes, but start fails). Always verify JARs are in plugin path.
11. **ERR_PIPE_DOES_NOT_EXIST_OR_NOT_AUTHORIZED with v4.x HP connector** — Pipe exists but connector role lacks required privileges. HP connector v4.x requires `OPERATE` privilege on pipe (not just `MONITOR`) and `SELECT` on table (not just `INSERT`) for Snowpipe Streaming API access.
12. **Multiple FAILED tasks with connector RUNNING** — `tasks.max` exceeds topic partition count. Each task processes specific partitions; excess tasks have no work and fail. Solution: Set `tasks.max` ≤ partition count, or increase topic partitions to match task count.
13. **V4 HP startup WARNs that are expected but require action** — Two WARNs fire once at connector registration and are not errors, but one is actionable:
    - `Config 'snowflake.enable.schematization' is not supported in KC v4. Schema evolution is now handled server-side via table property 'ENABLE_SCHEMA_EVOLUTION'.` — Informational only. Remove the key from your config to suppress it. If you need schema evolution on a pre-created table, run `ALTER TABLE ... SET ENABLE_SCHEMA_EVOLUTION = TRUE`.
    - `CLIENT-SIDE VALIDATION DISABLED (High-Performance Mode). Running without client-side validation requires a configured SSv2 Error Table to prevent records from being silently dropped.` — **Actionable.** HP mode skips per-row schema/type validation for throughput. Malformed records are not rejected at the connector — they are silently dropped unless an SSv2 error table is configured. Configure an error table or accept that malformed records will be lost without a trace.

## Connector Troubleshooting

### Diagnosing Version Mismatch

**Symptom:** Connector shows RUNNING but 0 rows land in Snowflake

```bash
# Check installed connector class
curl -s http://localhost:8083/connector-plugins | jq '.[] | select(.class | contains("Snowflake"))'

# If output shows v3.x class:
# {
#   "class": "com.snowflake.kafka.connector.SnowflakeSinkConnector",
#   "version": "3.5.3"
# }
# You need to upgrade to v4.x
```

**Fix:** Rebuild kafka-connect container with v4.x connector (see Installation section above)

### Diagnosing Missing Dependencies

**Symptom:** HTTP 500 error when creating connector, logs show `NoClassDefFoundError`

```bash
# Check Kafka Connect logs for Bouncy Castle errors
docker logs payments-kafka-connect --tail 100 | grep -i bouncy

# If you see:
# NoClassDefFoundError: org/bouncycastle/jcajce/provider/BouncyCastleFipsProvider
# → Missing BC-FIPS jars

# Verify JARs are present in container
docker exec payments-kafka-connect ls -la /usr/share/confluent-hub-components/snowflakeinc-snowflake-kafka-connector/
```

**Fix:** Add BC-FIPS jars to Dockerfile (see Installation section)

### Diagnosing Config Variable Substitution

**Symptom:** Connector fails with "Invalid Snowflake URL" showing `${env:SNOWFLAKE_URL}` literally

```bash
# Check connector status
curl -s http://localhost:8083/connectors/auth-events-sink-payments/status | jq -r '.connector.trace'

# If trace shows:
# Message: input url: ${env:SNOWFLAKE_URL}
# → Environment variable not being resolved
```

**Fix:** Use hardcoded values in connector config instead of `${env:}` syntax:

```json
{
  "snowflake.url.name": "orgname-accountname.snowflakecomputing.com:443",
  "snowflake.user.name": "USERNAME",
  "snowflake.private.key": "MII..."
}
```

### Check connector status
```bash
# List connectors
curl http://localhost:8083/connectors

# Get connector status
curl http://localhost:8083/connectors/auth-events-snowflake-sink/status

# Get connector config
curl http://localhost:8083/connectors/auth-events-snowflake-sink/config | jq
```

### Check Snowflake ingestion
```sql
-- Check table row count
SELECT COUNT(*) FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW;

-- Check latest ingested rows
SELECT * FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW ORDER BY INGESTED_AT DESC LIMIT 10;

-- Check pipe status (if using user-defined pipe)
SHOW PIPES LIKE 'AUTH_EVENTS_RAW' IN SCHEMA PAYMENTS_DB.RAW;

-- Check for rejected rows
SELECT * FROM TABLE(VALIDATE_PIPE_LOAD(
    PIPE_NAME => 'PAYMENTS_DB.RAW.AUTH_EVENTS_RAW',
    START_TIME => DATEADD(HOUR, -1, CURRENT_TIMESTAMP())
));
```

### Restart connector after config changes
```bash
# Restart connector
curl -X POST http://localhost:8083/connectors/auth-events-snowflake-sink/restart

# Delete and recreate connector
curl -X DELETE http://localhost:8083/connectors/auth-events-snowflake-sink
curl -X POST -H "Content-Type: application/json" \
  --data @kafka-connect/shared.json \
  http://localhost:8083/connectors
```

### Recovering from Docker Volume Prune

`docker system prune --volumes` wipes Kafka's data directory, destroying all topics including the internal Connect bookkeeping topics. This causes a cascade of failures if kafka-connect is still running.

**Failure sequence:**
1. Kafka restarts fresh with no topics
2. kafka-connect (still running) reconnects and Kafka auto-creates `_connect-configs/offsets/status` with `cleanup.policy=delete`
3. Restarting kafka-connect fails immediately: `TopicAdmin.verifyTopicCleanupPolicyOnlyCompact`
4. After fixing and restarting, connector config is gone (was in deleted `_connect-configs` topic)

**Full recovery procedure:**

```bash
# 1. Start the broker if it was pruned
docker compose up -d kafka

# 2. Delete the misconfigured internal topics (auto-created with wrong policy)
docker exec payments-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka:29092 --delete --topic _connect-configs
docker exec payments-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka:29092 --delete --topic _connect-offsets
docker exec payments-kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka:29092 --delete --topic _connect-status

# 3. Start kafka-connect (recreates topics with correct compact policy)
docker compose up -d kafka-connect

# 4. Wait for healthy, then re-register connector from local config
sleep 20
curl -s -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  --data @kafka-connect/shared.json

# 5. Verify RUNNING
curl -s http://localhost:8083/connectors/auth-events-sink-payments/status \
  | jq '.connector.state, .tasks[].state'
```

**Prevention:** Use `docker builder prune -f` instead of `docker system prune --volumes` to free build cache without touching running/stopped containers or volumes. Only use `--volumes` when a full reset is intentional, then bring the full stack down first:
```bash
docker compose down
docker system prune --volumes
docker compose up -d
```

**Key rule:** `kafka-connect/shared.json` is the authoritative connector config. The `_connect-configs` Kafka topic is a runtime cache — it does not survive a volume prune.

---

## Operational Remediation: Snowpipe Streaming Failure Modes

This section covers failure modes encountered during sustained high-throughput ingestion (30k–50k+ rps) that require specific remediation — **not** generic connector restarts. These patterns apply to both V3 (`SnowflakeSinkConnector` with Snowpipe Streaming mode) and V4 HP (`SnowflakeStreamingSinkConnector`), since both use Snowpipe Streaming channels internally.

### Issue 1: Stale Snowpipe Streaming Channel Offsets (Records Silently Skipped)

**Trigger:** Kafka data is wiped (topic deletion + recreation, or `docker volume prune`) without also clearing Snowflake's Snowpipe Streaming channel state. When the topic is recreated, Kafka offsets start from 0, but Snowflake channels still hold the old committed offset (e.g., 120,441,204).

**Symptom:** Connector shows `RUNNING`, tasks show `RUNNING`, but zero new rows land in Snowflake. Connector logs show:

```
Channel PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V3.PAYMENTS.AUTH.V3_0 -
  skipping current record - expected offset 120441204 but received 92121199
```

All new records are skipped because their Kafka offsets are lower than the channel's committed offset.

**Why restarts don't help:** The committed offset lives in Snowflake's channel metadata, not in Kafka or the Connect worker. Restarting the connector or the Connect container re-opens the same channel with the same stale offset.

**Remediation options (in order of preference):**

1. **Prevention (best):** Never wipe Kafka data independently. Use a coordinated reset that drops both Kafka topics and Snowflake target tables together. Example `make demo-reset` pattern:
   ```bash
   docker-compose down          # Stop all services including Connect
   rm -rf ./kafka-data          # Wipe Kafka data
   snow sql -q "DROP TABLE IF EXISTS PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V4"
   snow sql -q "DROP TABLE IF EXISTS PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V3"
   docker-compose up -d         # Restart everything fresh
   # Re-register connectors (they auto-create tables with fresh channels)
   ```

2. **New table name:** Change the target table in connector config (e.g., `AUTH_EVENTS_RAW` → `AUTH_EVENTS_RAW_V2`). Channels are keyed on `{database}.{schema}.{table_name}`, so a new table name creates fresh channels with offset 0. Then delete and re-register the connector.

3. **Drop table + delete/re-register connector:** Drop the Snowflake table, delete the connector via REST API, wait a few seconds, then re-register. The connector auto-creates the table with fresh channels. **Caveat:** This can trigger `ERR_PIPE_IN_INVALID_STATE` (see Issue 2 below) if time-travel metadata still references the old table.

**Unconfirmed:** The property `snowflake.streaming.offset.reset.strategy` has been referenced in some community discussions as a way to reset channel offsets without table changes. As of V4 RC9 and V3 2.3.x, this property is **not confirmed to exist** in official Snowflake documentation or connector source. Do not rely on it without testing.

**Channel name format:** `<CONNECTOR_NAME_UPPER>_<HASH>_<TOPIC>_<PARTITION>` — the hash is deterministic per connector name. Changing the connector name changes the hash and thus the channel name, but the underlying Snowpipe Streaming pipe is keyed on the **table**, not the channel name. So changing only the connector name is insufficient if the pipe state is the problem.

### Issue 2: `ERR_PIPE_IN_INVALID_STATE` (HTTP 409) After Table Drop

**Trigger:** A Snowflake target table with active Snowpipe Streaming channels is dropped and recreated with the same name. The internal streaming pipe (keyed on `{database}.{schema}.{table_name}`) retains metadata from the dropped table due to time-travel and fail-safe retention. The pipe references a table version that no longer matches, entering a permanently invalid state.

**Symptom:** All tasks fail immediately after startup with:

```
ERR_PIPE_IN_INVALID_STATE (HTTP 409)
```

Connector shows `RUNNING` but all tasks show `FAILED`.

**Why restarts don't help:** The pipe state is server-side in Snowflake, tied to the table name. Restarting connectors, changing connector names, or recreating Connect containers all open channels against the same poisoned pipe.

**What does NOT fix it:**
- Dropping and recreating the table (pipe metadata persists through time-travel)
- Changing connector name (pipe is per-table, not per-connector)
- Restarting the Kafka Connect container
- Restarting individual failed tasks

**Remediation options:**

1. **New table name (immediate fix):** Change `snowflake.topic2table.map` in connector config to point to a new table name (e.g., `AUTH_EVENTS_RAW` → `AUTH_EVENTS_RAW_V4`). Delete and re-register the connector. The connector auto-creates the new table with a fresh pipe.

2. **Wait for time-travel expiry:** If you must keep the original table name, wait for the time-travel retention period (default 1 day, up to 90 days for Enterprise+) plus the 7-day fail-safe period. After that, the pipe metadata is fully purged and the table name can be safely reused.

3. **`ALTER TABLE ... RENAME`:** Rename the existing table to a different name, then create a new table with the original name. This may or may not clear the pipe state depending on whether the pipe references the table by name or by internal ID. **Test before relying on this approach.**

**Prevention:** If you need to reset a table, prefer `TRUNCATE TABLE` over `DROP TABLE` — truncation preserves the table identity and pipe binding. For a full reset, always use a new table name or coordinate with the `demo-reset` approach that changes table names in connector configs.

### Issue 3: `MemoryThresholdExceeded` (HTTP 429) — Snowflake Ingest Node Memory Pressure

**Trigger:** The Snowflake ingest node (server-side) is under memory pressure, typically at 93%+ system memory utilization. This happens during sustained high-throughput ingestion, especially with multiple concurrent connectors or large batch sizes.

**Symptom:** Tasks fail with retry exhaustion after ~20 attempts. Connector logs show:

```
MemoryThresholdExceeded - System memory is at 93.XX% utilization.
Please reduce your client request rate. (HTTP 429)
```

Tasks transition from `RUNNING` → `FAILED` one by one as each exhausts its retry budget.

**Why restarts don't help (and make things worse):** This is a server-side throttle signal, not a client-side bug. Restarting the connector causes all tasks to reconnect simultaneously, creating a burst of new `appendRow` calls that further increases memory pressure. The correct response is to **reduce load**, not restart.

**Remediation:**

1. **Reduce ingestion rate at the source:** Lower the event generator rate. The 429 is Snowflake saying "slow down." Honor the backoff.

2. **Let built-in retry handle transient spikes:** Both V3 and V4 connectors have built-in retry with exponential backoff for 429 responses (~20 attempts). If the memory pressure is transient (e.g., concurrent large queries finishing), the connector recovers automatically. Only intervene if tasks actually reach `FAILED` state.

3. **After tasks fail, fix the rate first, then restart:** Once you've reduced the source rate:
   ```bash
   # For V4 HP (4 tasks) — restart individual tasks
   curl -X POST http://localhost:8083/connectors/auth-events-sink-v4/tasks/0/restart
   curl -X POST http://localhost:8083/connectors/auth-events-sink-v4/tasks/1/restart
   # ... etc.

   # For V3 — delete and re-register (single task, less risk of channel conflicts)
   curl -X DELETE http://localhost:8084/connectors/auth-events-sink-v3
   sleep 2
   curl -X POST -H "Content-Type: application/json" \
     --data @kafka-connect-v3/shared.json \
     http://localhost:8084/connectors
   ```

4. **Monitor before scaling up:** After recovery, gradually increase the rate while monitoring:
   ```sql
   -- Check ingestion lag (V4 structured table)
   SELECT DATEDIFF('second', MAX(EVENT_TS), SYSDATE()) AS lag_seconds
   FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V4;

   -- Check row counts over time
   SELECT COUNT(*) FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V4;
   ```

**Key principle:** 429 is a rate signal, not an error to fix. The connector's retry logic is designed to handle it. Only escalate to human intervention when tasks reach `FAILED` state after all retries are exhausted.

### Additional Operational Notes

**Task restart vs. connector delete/re-register:**
- **Individual task restart** (`POST /connectors/{name}/tasks/{id}/restart`) is lightweight but can cause `Channel has already been opened on the client` errors during partition rebalancing, especially with multiple tasks.
- **Full connector delete + re-register** (`DELETE /connectors/{name}` then `POST /connectors`) is heavier but gives clean partition assignments. Preferred for V3 (1 task) or when multiple V4 tasks have failed.

**Channel conflict error:**
```
Channel AUTH_EVENTS_SINK_V4_608480759_payments.auth_0 has already been opened on the client
```
This occurs when a task restart races with partition rebalancing. Fix: delete the entire connector and re-register.

### External Sources and Validation

- **Snowflake Kafka Connector documentation:** [Snowflake Kafka Connector Overview](https://docs.snowflake.com/en/user-guide/kafka-connector-overview) — covers V3 architecture, Snowpipe Streaming mode, and configuration reference.
- **Snowpipe Streaming channel semantics:** Channel offset tracking and exactly-once delivery are documented in [Snowpipe Streaming Overview](https://docs.snowflake.com/en/user-guide/data-load-snowpipe-streaming-overview).
- **`ERR_PIPE_IN_INVALID_STATE` behavior:** Observed empirically in this project. The relationship between table drops, time-travel metadata, and pipe state is not explicitly documented but is consistent with Snowflake's time-travel architecture where dropped objects retain metadata for the retention period.
- **`MemoryThresholdExceeded` (HTTP 429):** Standard HTTP rate-limiting semantics. Snowflake's ingest node returns 429 when system memory exceeds thresholds. The connector's retry-with-backoff behavior is the expected client response.
- **`snowflake.streaming.offset.reset.strategy`:** **NOT VALIDATED.** This property name appears in some community threads but is not found in official Snowflake connector documentation or the V4 RC9 configuration reference as of January 2025. Do not use without independent verification against the connector source code or official docs.
- **Channel name format** (`<CONNECTOR_NAME>_<HASH>_<TOPIC>_<PARTITION>`): Observed from connector logs. The hash is deterministic per connector name.
- **Pipe keyed on table name, not connector name:** Confirmed empirically — changing connector name (and thus channel hash) did not resolve `ERR_PIPE_IN_INVALID_STATE`. Only changing the table name resolved it.

---

## Quick Reference

```bash
# Deploy connector config via CI
curl -f -X POST -H "Content-Type: application/json" \
  --data @kafka-connect/shared.json \
  "${KAFKA_CONNECT_URL}/connectors"

# Check connector health
curl "${KAFKA_CONNECT_URL}/connectors/auth-events-snowflake-sink/status" | jq '.connector.state'

# View Kafka Connect logs (Docker)
docker logs payments-kafka-connect

# Check Snowflake table for data
snowsql -q "SELECT COUNT(*) FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW;"
```
