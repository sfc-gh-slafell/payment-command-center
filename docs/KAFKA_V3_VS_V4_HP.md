# Kafka Connector V3 vs V4 HP — Architecture Reference

Reference document for issue #59: adding a V3 connector path alongside the existing V4 HP connector and displaying throughput side-by-side.

---

## Quick Reference

| Dimension | V3 (Snowpipe mode) | V3 (Streaming Classic mode) | V4 HP |
|---|---|---|---|
| Connector class | `SnowflakeSinkConnector` | `SnowflakeSinkConnector` | `SnowflakeStreamingSinkConnector` |
| Ingestion backend | Snowpipe (file batch) | Snowpipe Streaming Classic | Snowpipe Streaming HPA |
| End-to-end latency | Minutes | Seconds–minutes | 5–10 seconds |
| Max throughput | Low (file-limited) | Moderate | Up to 10 GB/s per table |
| Billing unit | Per-file serverless compute | Client connections + compute | Per uncompressed GB ingested |
| Staging files | Yes (internal stage) | No | No |
| Snowflake PIPE syntax | `FROM @stage` | Channels (no pipe DDL) | `FROM TABLE(DATA_SOURCE(TYPE => 'STREAMING'))` |
| Deprecation status | Supported | **Planned deprecation mid-2026** | Public Preview (future standard) |

---

## The Three Modes — What "V3 vs V4" Actually Means

The version numbering is connector-level but the underlying architecture matters more than the version number.

### V3 — `SnowflakeSinkConnector` (two sub-modes)

**Sub-mode A: Snowpipe (default)**
- Connector buffers records locally, writes staged files to a Snowflake internal stage, then calls the Snowpipe REST API to load those files.
- Latency is proportional to buffer flush time + file load time = typically **1–5 minutes**.
- Each topic partition gets its own auto-created internal stage and pipe.
- Billing: serverless compute credits per file load.

**Sub-mode B: Snowpipe Streaming Classic** (opt-in via `snowflake.ingestion.method=SNOWPIPE_STREAMING`)
- Connector streams rows directly via the Snowflake Ingest Java SDK (no staging files).
- Latency drops to **seconds–minutes** depending on buffer flush config.
- This is the sub-mode being deprecated (formal announcement mid-2026, then 18-month sunset).

### V4 HP — `SnowflakeStreamingSinkConnector`

- Snowpipe Streaming High-Performance Architecture — the only mode available.
- Rust-based client core (lower resource usage than the Java SDK in V3).
- Streams via a PIPE object — no staging files, no buffer tuning.
- Target: **5–10 second end-to-end latency**, up to **10 GB/s per table**.
- Billing: flat-rate per uncompressed GB ingested (more predictable than compute-based).
- Currently Public Preview (v4.0.0-rc9 as of this project); migration from V3 is **manual only**.

---

## Critical Configuration Differences

### Connector class — the #1 cause of silent data loss

```json
// V3
{ "connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector" }

// V4 HP
{ "connector.class": "com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector" }
```

Using the V3 class with a V4 setup (or vice versa) results in the connector showing `RUNNING` with 0 rows landing in Snowflake. No error is logged. See DEPLOY_TROUBLESHOOTING.md Issue 19.

### Keys that exist in V3 but are removed or renamed in V4

| Config Key | V3 | V4 HP | Notes |
|---|---|---|---|
| `snowflake.ingestion.method` | Required to opt into streaming (`SNOWPIPE_STREAMING`) | **REMOVED** | V4 only supports HPA — key is unrecognised and causes startup errors if present |
| `snowflake.metadata.offsetAndPartition` | Valid (camelCase) | **REMOVED** | Renamed to dot-separated form |
| `snowflake.metadata.offset.and.partition` | Not valid | Valid | Correct key for V4; silently ignored in V3 |
| `buffer.flush.time` | Configurable (default 10s) | Not applicable | V4 manages flushing internally |
| `buffer.count.records` | Configurable (default 10000) | Not applicable | V4 manages flushing internally |
| `buffer.size.bytes` | Configurable (default 20 MB) | Not applicable | V4 manages flushing internally |
| `snowflake.streaming.max.client.lag` | Configurable (default 30s in v3.1.1+) | Not applicable | V4 manages client lag internally |
| `enable.streaming.client.optimization` | V3 only — one client per connector | Not applicable | V4 handles this internally |

### Minimal V3 config (Snowpipe Streaming Classic mode)

```json
{
  "name": "auth-events-sink-v3",
  "config": {
    "connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector",
    "tasks.max": "1",
    "topics": "payments.auth.v3",

    "snowflake.ingestion.method": "SNOWPIPE_STREAMING",

    "snowflake.url.name": "${env:SNOWFLAKE_URL}",
    "snowflake.user.name": "${env:SNOWFLAKE_USER}",
    "snowflake.private.key": "${env:SNOWFLAKE_PRIVATE_KEY}",
    "snowflake.database.name": "PAYMENTS_DB",
    "snowflake.schema.name": "RAW",
    "snowflake.role.name": "PAYMENTS_INGEST_ROLE",

    "snowflake.topic2table.map": "payments.auth.v3:AUTH_EVENTS_RAW_V3",

    "snowflake.metadata.offsetAndPartition": "true",
    "snowflake.metadata.createtime": "true",

    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",

    "errors.tolerance": "all",
    "errors.log.enable": "true"
  }
}
```

### Current V4 HP config (for reference, from `kafka-connect/shared.json`)

```json
{
  "name": "auth-events-sink-payments",
  "config": {
    "connector.class": "com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector",
    "tasks.max": "1",
    "topics": "payments.auth",

    "snowflake.url.name": "${env:SNOWFLAKE_URL}",
    "snowflake.user.name": "${env:SNOWFLAKE_USER}",
    "snowflake.private.key": "${env:SNOWFLAKE_PRIVATE_KEY}",
    "snowflake.database.name": "PAYMENTS_DB",
    "snowflake.schema.name": "RAW",
    "snowflake.role.name": "PAYMENTS_INGEST_ROLE",

    "snowflake.topic2table.map": "payments.auth:AUTH_EVENTS_RAW",
    "snowflake.metadata.topic": "true",
    "snowflake.metadata.offset.and.partition": "true",

    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",

    "errors.tolerance": "all",
    "errors.log.enable": "true"
  }
}
```

---

## Snowflake Objects: What Each Connector Creates

### V3 — Snowpipe (default mode)

The connector auto-creates all objects on first run:

```
AUTH_EVENTS_RAW_V3              ← table (RECORD_CONTENT VARIANT, RECORD_METADATA VARIANT)
SNOWFLAKE_KAFKA_CONNECTOR_<n>   ← internal stage (one per topic)
SNOWFLAKE_KAFKA_CONNECTOR_<n>   ← pipe (one per topic partition, FROM @stage)
```

You do not define these objects. The connector owns them. `RECORD_CONTENT` holds the raw message JSON; `RECORD_METADATA` holds Kafka provenance (topic, partition, offset).

### V3 — Snowpipe Streaming Classic mode

No staging files. The connector opens streaming channels per partition. No pipe DDL is required or used.

### V4 HP — Snowpipe Streaming HPA

The connector uses a **PIPE object** as the central component. Two modes:

**Default pipe mode** — connector auto-creates a pipe named `{TABLE}-STREAMING`. The pipe maps first-level JSON keys to matching table columns. No custom DDL needed.

**User-defined pipe mode** — you create the pipe (name must match the table name), giving full control over column mapping, type casting, and metadata extraction:

```sql
-- V4 HP user-defined pipe — required syntax
CREATE OR REPLACE PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW AS
COPY INTO PAYMENTS_DB.RAW.AUTH_EVENTS_RAW (
    EVENT_ID, PAYMENT_ID, SOURCE_TOPIC, SOURCE_PARTITION, SOURCE_OFFSET, INGESTED_AT
)
FROM (
    SELECT
        $1:event_id::VARCHAR(64),
        $1:payment_id::VARCHAR(64),
        $1:RECORD_METADATA:topic::VARCHAR(128),
        $1:RECORD_METADATA:partition::NUMBER,
        $1:RECORD_METADATA:offset::NUMBER,
        CURRENT_TIMESTAMP()
    FROM TABLE(DATA_SOURCE(TYPE => 'STREAMING'))  -- V4 HP only; do NOT use @stage
);
```

**The `DATA_SOURCE(TYPE => 'STREAMING')` clause is V4 HP only.** Using a stage path (`FROM @stage`) in a V4 pipe will fail at ingestion time.

---

## Required Snowflake Privileges

### V3 (Snowpipe Streaming Classic)

```sql
GRANT USAGE ON DATABASE PAYMENTS_DB TO ROLE PAYMENTS_INGEST_ROLE;
GRANT USAGE ON SCHEMA PAYMENTS_DB.RAW TO ROLE PAYMENTS_INGEST_ROLE;
GRANT INSERT ON TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V3 TO ROLE PAYMENTS_INGEST_ROLE;
-- SELECT is NOT required for V3 Streaming Classic
```

The connector auto-creates the table on first run if it doesn't exist (requires `CREATE TABLE` on the schema if you want auto-creation; otherwise create the table manually before starting the connector).

### V4 HP — two privileges that are different from V3

```sql
GRANT USAGE ON DATABASE PAYMENTS_DB TO ROLE PAYMENTS_INGEST_ROLE;
GRANT USAGE ON SCHEMA PAYMENTS_DB.RAW TO ROLE PAYMENTS_INGEST_ROLE;
GRANT INSERT ON TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;
GRANT SELECT ON TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE; -- REQUIRED (not needed in V3)

-- If using a user-defined pipe:
GRANT OPERATE ON PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE; -- OPERATE, not MONITOR
-- MONITOR only allows reading pipe metadata; OPERATE is required for Snowpipe Streaming API access
-- USAGE is not a valid privilege for PIPE objects
```

Without `SELECT`, V4 HP fails with `ERR_PIPE_DOES_NOT_EXIST_OR_NOT_AUTHORIZED` even though the pipe exists. See DEPLOY_TROUBLESHOOTING.md Issue 23.

---

## Default Table Schema Difference

**V3 (both modes) — always two VARIANT columns:**

```sql
-- Auto-created by V3 connector
CREATE TABLE AUTH_EVENTS_RAW_V3 (
    RECORD_CONTENT  VARIANT,   -- the full Kafka message JSON
    RECORD_METADATA VARIANT    -- { topic, partition, offset, CreateTime, ... }
);
```

Queries require semi-structured syntax: `SELECT record_content:event_id::VARCHAR FROM AUTH_EVENTS_RAW_V3`.

**V4 HP default pipe — columns per JSON key:**

```sql
-- Auto-created by V4 HP connector (default pipe mode, JSON input)
CREATE TABLE AUTH_EVENTS_RAW (
    EVENT_ID        VARCHAR,
    PAYMENT_ID      VARCHAR,
    ...
    RECORD_METADATA VARIANT    -- metadata always available
);
```

**V4 HP user-defined pipe — fully explicit:**

You define every column in your CREATE TABLE + CREATE PIPE. This is what this project uses (see DEPLOY_TROUBLESHOOTING.md Issue 22).

---

## Data Type Handling — Silent Breaking Change

This matters if your Kafka messages contain ARRAY or VARIANT fields.

| Field type | V3 Classic | V4 HP |
|---|---|---|
| `OBJECT` | Parses JSON strings automatically | Parses JSON strings automatically (no change) |
| `ARRAY` | Implicitly parses: `"[1,2]"` → `[1,2]` | Type-strict: `"[1,2]"` stays as `"[1,2]"` |
| `VARIANT` | Implicitly parses: `"true"` → `true` | Type-strict: `"true"` stays as `"true"` |

**For this project:** The event generator produces flat JSON (all primitive types), so this difference does not affect payment events. It would matter if you added nested JSON arrays.

---

## Installation

### V3 (Confluent Hub — straightforward)

```dockerfile
FROM confluentinc/cp-kafka-connect:7.6.0
RUN confluent-hub install --no-prompt snowflakeinc/snowflake-kafka-connector:3.5.3
```

No extra dependencies. The Confluent Hub package bundles all required JARs.

### V4 HP (Maven Central — requires manual JAR downloads)

```dockerfile
FROM confluentinc/cp-kafka-connect:7.6.0

# V4 HP RC versions are NOT on Confluent Hub stable channel
# Must download from Maven Central + Bouncy Castle FIPS (not regular BC)
RUN mkdir -p /usr/share/confluent-hub-components/snowflakeinc-snowflake-kafka-connector && \
    cd /usr/share/confluent-hub-components/snowflakeinc-snowflake-kafka-connector && \
    curl -sLO https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/4.0.0-rc9/snowflake-kafka-connector-4.0.0-rc9.jar && \
    curl -sLO https://repo1.maven.org/maven2/org/bouncycastle/bc-fips/1.0.2.5/bc-fips-1.0.2.5.jar && \
    curl -sLO https://repo1.maven.org/maven2/org/bouncycastle/bcpkix-fips/1.0.7/bcpkix-fips-1.0.7.jar
```

**Critical:** V4 HP requires Bouncy Castle FIPS (`bc-fips`, `bcpkix-fips`), **not** regular Bouncy Castle (`bcprov`, `bcpkix`). Using the wrong variant causes `NoClassDefFoundError: BouncyCastleFipsProvider` at connector startup. See DEPLOY_TROUBLESHOOTING.md (kafka-connect/Dockerfile notes).

---

## Billing: How to Measure Each Connector

### V3 Snowpipe Streaming Classic

Credits billed under service type `SNOWPIPE_STREAMING` in `ACCOUNT_USAGE.METERING_HISTORY`, based on active client connections and serverless compute.

```sql
SELECT
    start_time,
    end_time,
    credits_used,
    service_type
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE service_type = 'SNOWPIPE_STREAMING'
  AND start_time >= DATEADD('HOUR', -24, CURRENT_TIMESTAMP())
ORDER BY start_time DESC;
```

### V4 HP

Flat-rate throughput billing per **uncompressed GB ingested** (not compute credits). Also appears in `METERING_HISTORY` with `service_type = 'SNOWPIPE_STREAMING'` but distinguished by the pipe entity:

```sql
SELECT
    m.start_time,
    m.end_time,
    m.credits_used,
    p.pipe_name
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY m
JOIN SNOWFLAKE.ACCOUNT_USAGE.PIPES p
  ON m.entity_id = p.pipe_id
  AND m.name = p.pipe_name
  AND m.service_type = 'SNOWPIPE_STREAMING'
WHERE p.pipe_name LIKE 'PAYMENTS_DB.RAW.%'
ORDER BY m.start_time DESC;
```

---

## Throughput Measurement for the Demo (Issue #59)

### Measuring V4 HP throughput

The V4 HP table uses a user-defined pipe (Issue 22) that extracts `RECORD_METADATA` fields into
individual named columns (`SOURCE_TOPIC`, `SOURCE_PARTITION`, `SOURCE_OFFSET`). There is **no
`RECORD_METADATA` VARIANT column** in `AUTH_EVENTS_RAW`. Latency is measured as event generation
time (`EVENT_TS`, from the payload) to Snowflake visibility (`INGESTED_AT`, set to
`CURRENT_TIMESTAMP()` in the COPY INTO) — the true end-to-end latency from producer to query.

```sql
-- Records per second and avg end-to-end latency — V4 HP
SELECT
    DATE_TRUNC('SECOND', INGESTED_AT)                                          AS second_bucket,
    COUNT(*)                                                                    AS records_per_sec,
    AVG(DATEDIFF('millisecond', EVENT_TS, INGESTED_AT))                        AS avg_ingest_latency_ms
FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW
WHERE INGESTED_AT >= DATEADD('MINUTE', -5, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY 1 DESC;
```

### Measuring V3 throughput (once `AUTH_EVENTS_RAW_V3` is set up)

V3 Snowpipe Streaming Classic also injects `SnowflakeConnectorPushTime` into `RECORD_METADATA`:

```sql
-- Records per second and avg latency — V3 Snowpipe Streaming Classic
-- Assumes RECORD_CONTENT/RECORD_METADATA VARIANT schema (V3 default)
SELECT
    DATE_TRUNC('SECOND', CURRENT_TIMESTAMP())                                  AS second_bucket,
    COUNT(*)                                                                    AS records_per_sec,
    AVG(DATEDIFF('millisecond',
        TO_TIMESTAMP(RECORD_METADATA:SnowflakeConnectorPushTime::BIGINT / 1000),
        CURRENT_TIMESTAMP()))                                                   AS avg_ingest_latency_ms
FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V3
WHERE RECORD_METADATA:CreateTime::BIGINT >= DATEADD('MINUTE', -5, CURRENT_TIMESTAMP())::NUMBER
GROUP BY 1
ORDER BY 1 DESC;
```

---

## Migration from V3 to V4: What Does NOT Work

V4 HP is **not a drop-in replacement** for V3. Snowflake explicitly states: "Currently the migration from 3.x and 2.x is not supported." Manual steps required:

1. **Different connector class** — cannot reuse the same connector config
2. **Different pipe syntax** — V3's auto-created pipes use `FROM @stage`; V4 HP pipes use `DATA_SOURCE(TYPE => 'STREAMING')` — incompatible
3. **Different table schema defaults** — V3 creates `RECORD_CONTENT/RECORD_METADATA` VARIANT pair; V4 HP default pipe creates per-key columns; user-defined pipe gives full control
4. **Different privilege requirements** — V4 HP requires `SELECT` + `OPERATE` that V3 does not need
5. **Different buffer tuning** — V3 exposes `buffer.flush.time`, `buffer.count.records`, etc.; V4 HP manages these internally (no equivalent config keys)

For this project, run them as **independent connectors on separate topics** (`payments.auth` for V4 HP, `payments.auth.v3` for V3) writing to separate tables (`AUTH_EVENTS_RAW` vs `AUTH_EVENTS_RAW_V3`). Do not attempt to share topics or pipes between them.

---

## Deprecation Timeline

| Component | Status | Action required |
|---|---|---|
| V3 connector (3.x.x) | Officially supported — recommended for non-HP use | None now |
| Snowpipe Streaming Classic backend (used by V3 + `SNOWPIPE_STREAMING`) | **Deprecation notice issued** — formal announcement planned mid-2026, then 18-month sunset | Begin planning migration |
| V4 HP connector (4.x.x) | Public Preview (early access) — intended future standard | Evaluate; migration from V3 is manual |

All future Snowflake investment goes into the HP architecture. The V3 Streaming Classic mode will eventually stop working after the 18-month sunset window following the mid-2026 formal announcement.

---

## Checklist for Adding the V3 Connector (Issue #59)

- [ ] Create Kafka topic `payments.auth.v3` (mirrored from `payments.auth`, same partitions)
- [ ] Create V3 connector Dockerfile (`kafka-connect-v3/Dockerfile`) installing `snowflakeinc/snowflake-kafka-connector:3.5.3` from Confluent Hub
- [ ] Create V3 connector config (`kafka-connect-v3/shared.json`) using `SnowflakeSinkConnector` class with `snowflake.ingestion.method=SNOWPIPE_STREAMING`
- [ ] Create destination table `PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V3` (two VARIANT columns, or columns matching generator JSON)
- [ ] Grant `INSERT` (and optionally `CREATE TABLE`) to `PAYMENTS_INGEST_ROLE` on `AUTH_EVENTS_RAW_V3` — `SELECT` is **not** required for V3
- [ ] Add V3 connector service to `docker-compose.yml`
- [ ] Verify both connectors running: `curl localhost:8083/connectors` (V4 HP) and `curl localhost:8084/connectors` (V3, separate port)
- [ ] Validate data landing in both tables before building the dashboard page
- [ ] Add `pages/4_Connector_Benchmark.py` querying both tables for side-by-side throughput/latency charts
