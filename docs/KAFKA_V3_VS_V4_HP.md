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

## V4 HP Advantages Over V3 Streaming Classic

A concise reference for the six architectural reasons to choose V4 HP over V3 Streaming Classic.
These hold regardless of current throughput — they are structural, not load-dependent.

| Advantage | V4 HP | V3 Streaming Classic |
|---|---|---|
| **Throughput ceiling** | Up to 10 GB/s per table | ~2,000 rps per task (Java SDK per-row limit) |
| **Billing model** | Flat rate per uncompressed GB ingested | Per client connection + serverless compute credits |
| **Buffer tuning** | None — managed internally | `buffer.flush.time`, `buffer.count.records`, `buffer.size.bytes`, `snowflake.streaming.max.client.lag` |
| **Client runtime** | Rust — low CPU/memory overhead | Java Ingest SDK — JVM heap pressure at high throughput |
| **Pipeline lag target** | 5–10 s (stable under any load) | Seconds–minutes (grows beyond per-task ceiling) |
| **Deprecation status** | Public Preview — future standard | **Planned deprecation mid-2026, 18-month sunset** |

### Throughput Ceiling

V4 HP is designed for **10 GB/s per table** throughput. V3 Streaming Classic is limited by the Java Ingest SDK's per-row overhead: each row requires an individual Ingest API call, and the SDK's threading model caps effective throughput at roughly **1,000–2,000 rps per task**. Once V3 exceeds this ceiling it accumulates Kafka consumer lag that grows unboundedly. V4 HP's micro-partition batching approach writes rows in bulk, making per-row overhead negligible at high rates.

*Demo environment note:* In a single-node Docker environment, the Kafka broker becomes the bottleneck before either connector's ceiling is reached, so both show equal throughput at demo rates. V4 HP's ceiling advantage is a production-scale property.

### Predictable Billing

V4 HP billing: **flat rate per uncompressed GB ingested** — scales linearly with data volume, no compute credit spikes.

V3 Streaming Classic billing: **per active client connection + serverless compute credits** — total cost varies with connection count, flush frequency, and re-connection events. Throughput spikes cause unpredictable credit consumption.

### Zero Buffer Tuning

V3 Streaming Classic exposes five tuning parameters that directly affect throughput and latency:

```
buffer.flush.time          (default 10s)
buffer.count.records       (default 10000)
buffer.size.bytes          (default 20 MB)
snowflake.streaming.max.client.lag  (default 30s in v3.1.1+)
enable.streaming.client.optimization
```

These parameters interact — reducing `buffer.flush.time` improves latency but increases billing; increasing `buffer.count.records` improves throughput but increases latency. Re-tuning is required as event size and throughput change.

V4 HP exposes none of these parameters. Micro-partition flushing is managed internally by Snowflake's HP architecture. Operators configure only `tasks.max`.

### Rust Client

V3 Streaming Classic uses the Snowflake Java Ingest SDK — a JVM-based runtime that is subject to GC pauses, heap sizing, and class-loading overhead. At sustained high throughput, heap pressure becomes a tuning concern (`-Xmx`, GC policy).

V4 HP uses a Rust-based streaming client. Rust's ownership model eliminates GC pauses, and the client's memory footprint is significantly lower than the JVM. This is observable in container CPU and memory utilization at high rps.

### Stable Pipeline Lag Under Load

V4 HP's 5–10 second end-to-end pipeline lag is a **design constant** of the HP architecture — it reflects the time to accumulate and flush a micro-partition, not a symptom of being under load. This lag is consistent from 100 rps to 10 GB/s.

V3 Streaming Classic has lower per-row minimum latency at low throughput (~2–5 seconds when comfortably within its ceiling). But once throughput exceeds the per-task ceiling, Kafka consumer lag accumulates and pipeline freshness degrades unboundedly. V4 HP does not have a "ceiling" beyond which lag grows.

### Deprecation Timeline

V3 Snowpipe Streaming Classic is on a defined deprecation path:
- **Mid-2026**: Formal Snowflake deprecation announcement
- **18 months post-announcement**: End of support / service shutdown
- **Action required now**: Evaluate migration timeline; track Snowflake release notes

V4 HP is Snowflake's designated replacement. All future HP streaming investment goes into V4. Migration is **manual only** — there is no automated upgrade path from V3 to V4 (see [Migration from V3 to V4](#migration-from-v3-to-v4-what-does-not-work)).

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
`RECORD_METADATA` VARIANT column** in `AUTH_EVENTS_RAW`.

**Critical caveats for V4 HP queries — see the Behavioral Gotchas section below:**

- Filter and bucket on `EVENT_TS` (per-row UTC timestamp from the generator), **not** `INGESTED_AT`.
  `INGESTED_AT` is set **once per micro-partition open** — using it in a time-window filter returns
  0 rows once the open partition's age exceeds the window.
- Use `SYSDATE()` (returns `TIMESTAMP_NTZ` in UTC natively) for time thresholds, **not**
  `CURRENT_TIMESTAMP()` (returns `TIMESTAMP_LTZ`). Comparing LTZ against `TIMESTAMP_NTZ EVENT_TS`
  causes implicit timezone conversion that produces incorrect results depending on session timezone.
- `INGESTED_AT − EVENT_TS` is **not a meaningful per-row latency** for HP mode. Use pipeline
  freshness (`DATEDIFF('second', MAX(EVENT_TS), SYSDATE())`) instead.

```sql
-- Records per second — V4 HP
-- Bucket and filter on EVENT_TS (per-row UTC); use SYSDATE() for NTZ threshold
SELECT
    DATE_TRUNC('SECOND', EVENT_TS)   AS second_bucket,
    COUNT(*)                          AS records_per_sec
FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW
WHERE EVENT_TS >= DATEADD('MINUTE', -5, SYSDATE())
GROUP BY 1
ORDER BY 1 DESC;

-- Pipeline freshness (how stale is the newest visible event)
SELECT DATEDIFF('second', MAX(EVENT_TS), SYSDATE()) AS pipeline_lag_sec
FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW;
```

### Measuring V3 throughput (once `AUTH_EVENTS_RAW_V3` is set up)

V3 Snowpipe Streaming Classic injects `SnowflakeConnectorPushTime` and `CreateTime` into
`RECORD_METADATA` as **Unix milliseconds** (BIGINT). Convert with `/ 1000` before `TO_TIMESTAMP`.
The per-row latency is meaningful here because each row's metadata is written individually.

```sql
-- Records per second and per-row latency — V3 Snowpipe Streaming Classic
-- RECORD_METADATA:CreateTime = Kafka producer timestamp (ms since epoch)
-- RECORD_METADATA:SnowflakeConnectorPushTime = time row was pushed to Snowflake (ms since epoch)
SELECT
    DATE_TRUNC('SECOND',
        TO_TIMESTAMP(RECORD_METADATA:SnowflakeConnectorPushTime::BIGINT / 1000)) AS second_bucket,
    COUNT(*)                                                                      AS records_per_sec,
    AVG(DATEDIFF('millisecond',
        TO_TIMESTAMP(RECORD_METADATA:CreateTime::BIGINT / 1000),
        TO_TIMESTAMP(RECORD_METADATA:SnowflakeConnectorPushTime::BIGINT / 1000))) AS avg_latency_ms
FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V3
WHERE TO_TIMESTAMP(RECORD_METADATA:SnowflakeConnectorPushTime::BIGINT / 1000)
    >= DATEADD('MINUTE', -5, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY 1 DESC;
```

---

## V4 HP Behavioral Gotchas

These are non-obvious behaviors specific to Snowpipe Streaming HPA that caused real production issues
in this project. None are bugs — they are correct Snowflake behavior, but they are underdocumented
and violate reasonable intuitions about per-row ingestion.

---

### Gotcha 1 — `INGESTED_AT` is per-micro-partition, not per-row

**What happens:** `INGESTED_AT DEFAULT CURRENT_TIMESTAMP()` in a user-defined pipe's `COPY INTO`
is evaluated **once when Snowpipe Streaming opens a micro-partition for writing** — not once per row.
All rows that accumulate in that open partition share the same `INGESTED_AT` value.

**Observed effect:** A micro-partition opened at `17:49:45`. Events with `EVENT_TS` of `17:58`
were written into that same partition. `INGESTED_AT − EVENT_TS = 17:49 − 17:58 = −8.5 minutes =
−510,000 ms`. The latency chart showed `AVG_LATENCY_MS = −500,000 ms`.

**Why it happens:** Snowpipe Streaming HPA buffers incoming rows in a micro-partition that stays
open until it reaches a size or time threshold. The `COPY INTO` expression is evaluated at
partition-open time, not at row-insert time. This is analogous to `DEFAULT` column expressions
in other batch ETL systems that capture a batch start timestamp.

**What you can measure instead:**
- **Pipeline freshness:** `DATEDIFF('second', MAX(EVENT_TS), SYSDATE())` — how stale is the
  newest visible event. Always positive and meaningful.
- **Partition flush latency:** `DATEDIFF('millisecond', MIN(EVENT_TS), INGESTED_AT)` within a
  single `INGESTED_AT` group — how long was the oldest event buffered before its partition was
  written. Positive and accurate, but requires grouping by `INGESTED_AT`.

**What you cannot measure:** True per-row ingest latency. HP mode does not expose it.

---

### Gotcha 2 — `CREATE OR REPLACE PIPE` invalidates all streaming channels (channel cleanup loop)

**What happens:** Any execution of `CREATE OR REPLACE PIPE` — even with an identical definition —
assigns a new internal pipe ID. Snowpipe Streaming channels are bound to the old pipe ID on the
server side. After the pipe is recreated, the connector enters a **channel cleanup loop**:

```
Task 0 now using pipe AUTH_EVENTS_RAW
Initialized streaming channel: AUTH_EVENTS_SINK_PAYMENTS_..._payments.auth_0
Fetched snowflake committed offset: 0
Cleaning up channel entry from cache: AUTH_EVENTS_SINK_PAYMENTS_..._payments.auth_0
[60 seconds pass]
Task 0 now using pipe AUTH_EVENTS_RAW    ← same cycle repeats
```

The connector log shows offsets advancing (the Kafka Consumer API accepts data), but **zero rows
land in the Snowflake table**. The connector shows `RUNNING` with no errors.

**Root cause:** The server-side channel state is associated with the pipe's internal ID, not its
name. Recreating the pipe changes the ID. The old channel name maps to a broken server-side binding.
Re-registering the channel under the same name does not clear this — the server still resolves the
name to the old pipe ID's state.

**The only fix:** Drop and recreate the **table** (not just the pipe). Dropping the table clears
all server-side channel state associated with it. A fresh table + fresh pipe + connector restart
creates clean channels with no stale bindings.

```sql
-- Fixes the channel cleanup loop — table drop is required, not just pipe drop
DROP TABLE IF EXISTS PAYMENTS_DB.RAW.AUTH_EVENTS_RAW;
-- Then recreate table + pipe via schemachange migration
```

**Prevention:** Never run `CREATE OR REPLACE PIPE` on a V4 HP pipe once the connector is live.
To change the pipe definition, always pair it with a table drop/recreate in the same migration.

---

### Gotcha 3 — `CURRENT_TIMESTAMP()` returns `TIMESTAMP_LTZ`; comparing with `TIMESTAMP_NTZ` uses session timezone

**What happens:** `EVENT_TS` is stored as `TIMESTAMP_NTZ` (timezone-naive UTC). When you filter:

```sql
WHERE EVENT_TS >= DATEADD('MINUTE', -5, CURRENT_TIMESTAMP())
```

Snowflake must resolve the type mismatch between `TIMESTAMP_NTZ EVENT_TS` and the
`TIMESTAMP_LTZ` result of `CURRENT_TIMESTAMP()`. Snowflake converts the NTZ value to LTZ using
the **session timezone**. In a PDT session (UTC-7), a stored UTC value of `17:00` is interpreted
as `17:00 PDT = 00:00 UTC next day` — approximately 7 hours in the future from the query's
perspective. This makes **all rows in the table pass the filter**, returning data from hours ago.

In an SPCS session (which defaults to UTC), the same query works correctly. The same code
produces different results depending on where it runs.

**The SPCS 0-data symptom:** Before V1.14.0, `INGESTED_AT` was stored as LTZ (PDT session).
Values were stored as `09:49:45 PDT`. The SPCS app's UTC session compared against
`CURRENT_TIMESTAMP() = 17:xx UTC`. All `INGESTED_AT` values were ~7 hours in the past from
the UTC threshold. Filter `INGESTED_AT >= 17:12 UTC` matched nothing because all stored
values were `09:49 PDT` (`16:49 UTC`). Result: 0 rows, 0 metrics on the dashboard.

**Fix:** Use `SYSDATE()` for time thresholds on `TIMESTAMP_NTZ` columns:

```sql
-- SYSDATE() returns TIMESTAMP_NTZ in UTC natively — no implicit conversion
WHERE EVENT_TS >= DATEADD('MINUTE', -5, SYSDATE())
```

`SYSDATE()` always returns the current time as `TIMESTAMP_NTZ` in UTC regardless of session
timezone. `NTZ vs NTZ` comparison requires no conversion and is safe in any session context.

---

### Gotcha 4 — `CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())` returns `TIMESTAMP_LTZ`, not `TIMESTAMP_NTZ`

**What happens:** The 2-argument form `CONVERT_TIMEZONE(target_tz, source_value)` preserves the
**type** of the input. `CURRENT_TIMESTAMP()` is `TIMESTAMP_LTZ`. After conversion, the result
is still `TIMESTAMP_LTZ` — displayed as `17:49:45 +0000` (looks like UTC, but is typed as LTZ).

Storing this in a `TIMESTAMP_NTZ` column works (the value is correct), but if you use it in a
comparison without an explicit `::TIMESTAMP_NTZ` cast, you still get LTZ-vs-NTZ implicit
conversion behavior, which is session-timezone-dependent.

**Diagnostic query that confirmed this:**

```sql
SELECT
    CURRENT_TIMESTAMP()                              AS ts_ltz,       -- TIMESTAMP_LTZ
    SYSDATE()                                         AS ts_ntz,       -- TIMESTAMP_NTZ (UTC)
    CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())      AS converted,    -- TIMESTAMP_LTZ (+0000)
    CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ AS converted_ntz;  -- correct NTZ
```

**Fix:** Always add `::TIMESTAMP_NTZ` when storing converted timestamps in NTZ columns or
comparing them with NTZ values:

```sql
-- In pipe COPY INTO — stores true UTC as NTZ type
CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ
```

Or simply use `SYSDATE()` directly — it's shorter, always NTZ, always UTC, no cast required.

---

### Gotcha 5 — `CREATE OR REPLACE PIPE` resets all grants

**What happens:** `CREATE OR REPLACE PIPE` is not an incremental operation. It drops and recreates
the pipe object. All `GRANT` statements previously applied to the old pipe object are lost.

After recreation, the connector role (`PAYMENTS_INGEST_ROLE`) has no privileges on the pipe and
immediately fails with `ERR_PIPE_DOES_NOT_EXIST_OR_NOT_AUTHORIZED` — even though the pipe exists
and is visible to `ACCOUNTADMIN`.

**Required re-grants after any pipe recreation:**

```sql
GRANT MONITOR ON PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;
GRANT OPERATE ON PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;
```

Both must be included in the same migration that creates the pipe. `MONITOR` alone is insufficient
(see DEPLOY_TROUBLESHOOTING.md Issue 23). `OPERATE` is required for Snowpipe Streaming API access.

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

## Live Observations: Sustained Run (April 2, 2026)

Both connectors observed under identical load from the `payments-generator` container.
Concrete numbers from Docker logs for empirical reference.

### V4 HP — Healthy, Continuous Operation

**S3 upload performance (Rust SDK, `.ndjson` format):**

| Metric | Observed range |
|---|---|
| Batch size processed | 2.37 MB – 2.98 MB per cycle |
| Compressed file size uploaded | 275 KB – 350 KB |
| Upload elapsed | 115 ms – 230 ms (typical); one spike to 721 ms |
| Cadence | ~1 file per second, uninterrupted |
| S3 path prefix | `streamingrowset/simplettl/` |
| File format | `.ndjson` |

**Process resource snapshot** (from `cyclone_shared::util::process_info_provider`):
```
process_used_memory_bytes: 1,627,176,960  (~1.55 GB)
system_total_memory_bytes: 8,216,776,704  (~7.9 GB)
cpu_usage_percent: 9.76%
num_workers: 12
num_tasks: 25
queue_depth: 0                            ← keeping up with generator
```

**Log character:** Pure `INFO`. Zero `ERROR` or data-related `WARN` lines after startup. The
only WARNs are one-time config notices at connector registration (see SKILL.md pitfall #13).

### V3 — Offset Crisis (stuck since 22:22:14 April 1)

**What happened:** The `payments.auth.v3` Kafka topic was reset. Kafka began redelivering
from offset 0. The Snowflake channel retained its committed offset of **120,441,204**. V3's
`DirectTopicPartitionChannel` correctly rejects any record whose offset is below the channel's
high-water mark.

**Gap math:**
```
Channel expects:    120,441,204
Kafka delivering:         0 – 2,528,258  (as of 22:51 April 1)
Records to skip before recovery: ~117.9 million
```

At the generator's rate, V3 would not reach offset 120,441,204 organically for many hours.
Every incoming record since 22:22:14 has been silently dropped.

**Log volume generated by the stall:**
```
2,528,258 WARN lines — one per skipped record
```

**Secondary warnings from the stall:**
```
WARN WorkerSinkTask{id=auth-events-sink-v3-0}
     Ignoring invalid task provided offset payments.auth.v3-0/
     OffsetAndMetadata{offset=120441205} -- not yet consumed, taskOffset=120441205 currentOffset=13638

WARN WorkerSinkTask{id=auth-events-sink-v3-0} Commit of offsets timed out
     (repeating every ~60 seconds)
```

Kafka Connect is attempting to commit offset 120,441,205 as complete, but the worker's actual
consumer position has not reached it. This causes a timeout loop that will persist until the
channel offset is reset.

**V3 upload performance when it WAS working** (S3 upload logs from 22:51, just before stall):

| Metric | Observed range |
|---|---|
| Blob size | 600 KB – 6.3 MB |
| Upload time | 800 ms – 1,475 ms |
| Row count per blob | 10,000 – 108,119 (variable; larger during catch-up bursts) |
| S3 path prefix | `streaming_ingest/` |
| File format | `.bdec` (columnar binary, gzip-compressed) |
| Upload concurrency | Up to 36 threads in Java thread pool |
| Registration round-trip | Explicit `registerBlobs` API call per batch |

The build → upload → register three-phase pipeline is visible in V3 logs. V4 HP has no
equivalent explicit registration step — it is handled server-side.

### Side-by-Side Upload Latency

| | V4 HP (Rust) | V3 (Java) |
|---|---|---|
| Typical upload | 115–230 ms | 800–1,475 ms |
| Relative speed | ~4–8× faster per file | Baseline |
| Format | `.ndjson` (pre-compressed inline) | `.bdec` (2-stage: build + gzip) |
| Registration | Server-side, not visible in logs | Explicit API round-trip per batch |

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
