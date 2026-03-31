# Getting Started with Snowflake HP Kafka Connector

Complete guide to setting up Snowflake's High Performance (HP) Kafka Connector v4.x for streaming data ingestion with 5-10 second latency.

**Estimated completion time:** 45-60 minutes

---

## Table of Contents

1. [Introduction & Prerequisites](#1-introduction--prerequisites)
2. [Common Mistakes (Read This First!)](#2-common-mistakes-read-this-first)
3. [Snowflake Setup](#3-snowflake-setup)
4. [Kafka Setup](#4-kafka-setup)
5. [Kafka Connect Setup](#5-kafka-connect-setup)
6. [Connector Configuration](#6-connector-configuration)
7. [Deploying the Connector](#7-deploying-the-connector)
8. [End-to-End Verification](#8-end-to-end-verification)
9. [Troubleshooting Guide](#9-troubleshooting-guide)
10. [Operating the Connector](#10-operating-the-connector)
11. [Performance Tuning](#11-performance-tuning-optional)
12. [Next Steps & Resources](#12-next-steps--resources)

---

## 1. Introduction & Prerequisites

### What is HP Kafka Connector v4.x?

The Snowflake HP (High Performance) Kafka Connector v4.x streams data from Kafka topics directly into Snowflake tables via Snowpipe Streaming, delivering 5-10 second ingestion latency with automatic schema handling and metadata capture.

**Key differences from v3.x:**
- **Different connector class** (StreamingSinkConnector vs SinkConnector)
- **Streaming-only mode** (no batch Snowpipe option)
- **Different configuration keys** (dot-separated vs camelCase for metadata)
- **Different privilege requirements** (OPERATE on pipes, SELECT on tables)

> ⚠️ **Critical:** Using v3.x patterns with v4.x causes silent data loss. Read Section 2 before starting.

### Prerequisites

Before starting, verify you have:

- [x] Snowflake account with **Snowpipe Streaming** enabled
- [x] Kafka cluster (v2.7+) with topics created
- [x] Kafka Connect cluster (v2.7+) with network access to Snowflake
- [x] Snowflake service account with key-pair authentication configured
- [x] Admin access to both Snowflake and Kafka Connect
- [x] Basic familiarity with Kafka, Snowflake SQL, and JSON

### What You'll Build

By the end of this guide, you'll have:
- A Snowflake table receiving real-time data from Kafka
- Kafka metadata columns (topic, partition, offset) populated automatically
- A connector that survives restarts and scales with your data
- Monitoring commands to verify healthy operation

---

## 2. Common Mistakes (Read This First!)

These five mistakes cause 90% of failed deployments. **Read this section first to save hours of troubleshooting.**

### Mistake #1: Wrong Connector Class ⚠️ (Silent Data Loss)

**Wrong (v3.x):**
```json
"connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector"
```

**Correct (HP v4.x):**
```json
"connector.class": "com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector"
```

**Symptom:** Connector shows `RUNNING`, but 0 rows land in Snowflake. No errors.
**Why critical:** v3.x class operates in legacy batch mode requiring different infrastructure. It silently fails in streaming-only setups.
**Prevention:** Always use `SnowflakeStreamingSinkConnector` for v4.x.

---

### Mistake #2: Missing Bouncy Castle FIPS JARs

**Symptom:** HTTP 500 error when creating connector. Logs show:
```
NoClassDefFoundError: org/bouncycastle/jcajce/provider/BouncyCastleFipsProvider
```

**Why it happens:** HP Connector v4.x requires **Bouncy Castle FIPS** libraries (`bc-fips` + `bcpkix-fips`), not regular Bouncy Castle (`bcprov` + `bcpkix`).

**Prevention:** Use the provided Dockerfile in Section 5 which downloads the correct FIPS JARs from Maven Central.

---

### Mistake #3: Wrong Metadata Configuration Keys

**Wrong (v3.x camelCase):**
```json
"snowflake.metadata.offsetAndPartition": "true"
```

**Correct (v4.x dot-separated):**
```json
"snowflake.metadata.offset.and.partition": "true"
```

**Symptom:** `SOURCE_TOPIC`, `SOURCE_PARTITION`, `SOURCE_OFFSET` columns remain NULL.
**Why critical:** v4.x silently ignores the camelCase key. Metadata columns never populate, breaking operational visibility.
**Prevention:** Always use dot-separated notation for all metadata keys in v4.x.

---

### Mistake #4: Missing OPERATE Privilege on Pipe

**Symptom:** Tasks show error:
```
ERR_PIPE_DOES_NOT_EXIST_OR_NOT_AUTHORIZED
```
Pipe exists and has `MONITOR` privilege, but connector still fails.

**Why it happens:** HP Connector v4.x accesses pipes via Snowpipe Streaming API, which requires `OPERATE` privilege (not just `MONITOR` for metadata).

**Prevention:** Grant **both** `MONITOR` and `OPERATE` on the pipe. Also grant `SELECT` (in addition to `INSERT`) on the table.

---

### Mistake #5: tasks.max Exceeds Partition Count

**Symptom:** Connector shows `RUNNING`, but multiple tasks show `FAILED`.

**Why it happens:** Kafka Connect creates one task per topic partition. If `tasks.max: 24` but topic has 1 partition:
- 1 task gets assigned to partition 0 → `RUNNING`
- 23 tasks have no partitions → `FAILED`

**Prevention:** Set `tasks.max` ≤ topic partition count. Start with `tasks.max: 1`, increase only if needed.

---

## 3. Snowflake Setup

*Estimated time: 15 minutes*

### 3.1 Create Database and Schema

```sql
CREATE DATABASE IF NOT EXISTS PAYMENTS_DB;
CREATE SCHEMA IF NOT EXISTS PAYMENTS_DB.RAW;
```

### 3.2 Create Landing Table

Create a table with business columns matching your JSON event structure, plus metadata columns for operational visibility:

```sql
CREATE TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW (
    -- Business columns (match your JSON keys)
    env                 VARCHAR(16)      NOT NULL,
    event_ts            TIMESTAMP_NTZ    NOT NULL,
    event_id            VARCHAR(64)      NOT NULL,
    payment_id          VARCHAR(64)      NOT NULL,
    merchant_id         VARCHAR(32)      NOT NULL,
    merchant_name       VARCHAR(256),
    region              VARCHAR(8)       NOT NULL,
    country             VARCHAR(4)       NOT NULL,
    card_brand          VARCHAR(16)      NOT NULL,
    issuer_bin          VARCHAR(8)       NOT NULL,
    payment_method      VARCHAR(16)      NOT NULL,
    amount              NUMBER(12,2)     NOT NULL,
    currency            VARCHAR(4)       NOT NULL,
    auth_status         VARCHAR(16)      NOT NULL,
    decline_code        VARCHAR(32),
    auth_latency_ms     INTEGER          NOT NULL,

    -- Metadata columns (populated by HP connector)
    source_topic        VARCHAR(128),
    source_partition    INTEGER,
    source_offset       BIGINT,

    -- Ingestion timestamp
    ingested_at         TIMESTAMP_NTZ    NOT NULL   DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Raw landing table for Kafka events'
DATA_RETENTION_TIME_IN_DAYS = 14;
```

**Key points:**
- Column names must match JSON keys (case-insensitive)
- Metadata columns (`source_topic`, `source_partition`, `source_offset`) are populated by the connector when properly configured
- `ingested_at` tracks when data arrived in Snowflake

### 3.3 Create User-Defined Pipe

> ⚠️ **Critical:** User-defined pipes are **required** to populate metadata columns. Without this, `SOURCE_TOPIC`, `SOURCE_PARTITION`, and `SOURCE_OFFSET` will be NULL.

The pipe name **must match the table name** to trigger user-defined pipe mode:

```sql
CREATE OR REPLACE PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW AS
COPY INTO PAYMENTS_DB.RAW.AUTH_EVENTS_RAW (
    ENV, EVENT_TS, EVENT_ID, PAYMENT_ID, MERCHANT_ID, MERCHANT_NAME,
    REGION, COUNTRY, CARD_BRAND, ISSUER_BIN, PAYMENT_METHOD,
    AMOUNT, CURRENCY, AUTH_STATUS, DECLINE_CODE, AUTH_LATENCY_MS,
    SOURCE_TOPIC, SOURCE_PARTITION, SOURCE_OFFSET,
    INGESTED_AT
)
FROM (
    SELECT
        $1:env::VARCHAR(16),
        $1:event_ts::TIMESTAMP_NTZ,
        $1:event_id::VARCHAR(64),
        $1:payment_id::VARCHAR(64),
        $1:merchant_id::VARCHAR(32),
        $1:merchant_name::VARCHAR(256),
        $1:region::VARCHAR(8),
        $1:country::VARCHAR(4),
        $1:card_brand::VARCHAR(16),
        $1:issuer_bin::VARCHAR(8),
        $1:payment_method::VARCHAR(16),
        $1:amount::NUMBER(12,2),
        $1:currency::VARCHAR(4),
        $1:auth_status::VARCHAR(16),
        $1:decline_code::VARCHAR(32),
        $1:auth_latency_ms::NUMBER,
        $1:RECORD_METADATA:topic::VARCHAR(128),       -- From connector metadata
        $1:RECORD_METADATA:partition::NUMBER,         -- From connector metadata
        $1:RECORD_METADATA:offset::NUMBER,            -- From connector metadata
        CURRENT_TIMESTAMP()                           -- Explicit for NOT NULL constraint
    FROM TABLE(DATA_SOURCE(TYPE => 'STREAMING'))
);
```

**Why user-defined pipes are required:**
- Auto-generated pipes only map top-level JSON keys to columns
- `RECORD_METADATA` (containing topic/partition/offset) is connector-injected, not in the message JSON
- User-defined pipes can access `$1:RECORD_METADATA:*` to extract metadata
- `CURRENT_TIMESTAMP()` must be explicit for NOT NULL columns (defaults don't apply in COPY INTO)

### 3.4 Create Service Account and Configure Key-Pair Auth

Generate an RSA key pair for service account authentication:

```bash
# Generate PKCS8 unencrypted private key
openssl genrsa 2048 | openssl pkcs8 -topk8 -nocrypt -out snowflake_key.p8

# Extract public key
openssl rsa -in snowflake_key.p8 -pubout -out snowflake_key_pub.pem

# Get public key content (without headers)
grep -v "BEGIN PUBLIC KEY" snowflake_key_pub.pem | grep -v "END PUBLIC KEY" | tr -d '\n'
```

Apply the public key to your service account:

```sql
ALTER USER KAFKA_INGEST_USER SET RSA_PUBLIC_KEY = '<public_key_content>';
```

### 3.5 Create Role and Grant Privileges

```sql
-- Create role for connector
CREATE ROLE IF NOT EXISTS PAYMENTS_INGEST_ROLE;

-- Grant role to service account
GRANT ROLE PAYMENTS_INGEST_ROLE TO USER KAFKA_INGEST_USER;

-- Database and schema access
GRANT USAGE ON DATABASE PAYMENTS_DB TO ROLE PAYMENTS_INGEST_ROLE;
GRANT USAGE ON SCHEMA PAYMENTS_DB.RAW TO ROLE PAYMENTS_INGEST_ROLE;

-- Table access (BOTH INSERT and SELECT required)
GRANT INSERT ON TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;
GRANT SELECT ON TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;

-- Pipe access (BOTH MONITOR and OPERATE required)
GRANT MONITOR ON PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;
GRANT OPERATE ON PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;
```

> 📌 **Why SELECT is required:** HP connector needs to read table schema for validation.
> 📌 **Why OPERATE is required:** Snowpipe Streaming API in v4.x requires OPERATE (not just MONITOR).

### 3.6 Verification Checkpoint

Verify your Snowflake setup:

```sql
-- Verify table exists
SHOW TABLES LIKE 'AUTH_EVENTS_RAW' IN SCHEMA PAYMENTS_DB.RAW;

-- Verify pipe exists with correct name
SHOW PIPES LIKE 'AUTH_EVENTS_RAW' IN SCHEMA PAYMENTS_DB.RAW;

-- Verify grants
SHOW GRANTS TO ROLE PAYMENTS_INGEST_ROLE;
-- Should show: USAGE on database/schema, INSERT + SELECT on table, MONITOR + OPERATE on pipe

-- Test role switching
USE ROLE PAYMENTS_INGEST_ROLE;
-- Should succeed without errors
```

**Success Criteria:**
- [x] Table shows in `SHOW TABLES` output
- [x] Pipe shows in `SHOW PIPES` output with `kind = STREAMING`
- [x] `SHOW GRANTS` includes INSERT, SELECT, MONITOR, OPERATE
- [x] `USE ROLE` succeeds without privilege errors

---

## 4. Kafka Setup

*Estimated time: 5 minutes*

### 4.1 Create Topic

Create a Kafka topic with appropriate partition count:

```bash
# For self-managed Kafka
kafka-topics.sh --bootstrap-server localhost:9092 \
  --create \
  --topic payments.auth \
  --partitions 24 \
  --replication-factor 3 \
  --config retention.ms=259200000

# For Confluent Cloud
confluent kafka topic create payments.auth \
  --partitions 24
```

**Partition count guidance:**
- Start with 1 for testing
- Production: 1 partition per 50-100 MB/s throughput
- Set `tasks.max` ≤ partition count in connector config

### 4.2 Verify Topic

```bash
# Describe topic
kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --topic payments.auth

# Verify connectivity from Kafka Connect cluster
kafka-console-consumer --bootstrap-server localhost:9092 \
  --topic payments.auth \
  --from-beginning --max-messages 1 --timeout-ms 5000
```

**Success Criteria:**
- [x] Topic exists with expected partition count
- [x] Kafka Connect can access the topic
- [x] No permission errors

---

## 5. Kafka Connect Setup

*Estimated time: 10 minutes*

### 5.1 Install HP Connector v4.x

> ⚠️ **Why not Confluent Hub?** HP Connector v4.x RC versions are only available on Maven Central. Confluent Hub only has v3.x stable releases.

**Docker Installation (Recommended):**

Create `Dockerfile`:

```dockerfile
FROM confluentinc/cp-kafka-connect:7.6.0

# Install Snowflake HP Kafka Connector v4.0.0-rc8 from Maven Central
# Requires Bouncy Castle FIPS cryptography libraries (not regular BC)
RUN mkdir -p /usr/share/confluent-hub-components/snowflakeinc-snowflake-kafka-connector && \
    cd /usr/share/confluent-hub-components/snowflakeinc-snowflake-kafka-connector && \
    curl -sLO https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/4.0.0-rc8/snowflake-kafka-connector-4.0.0-rc8.jar && \
    curl -sLO https://repo1.maven.org/maven2/org/bouncycastle/bc-fips/1.0.2.5/bc-fips-1.0.2.5.jar && \
    curl -sLO https://repo1.maven.org/maven2/org/bouncycastle/bcpkix-fips/1.0.7/bcpkix-fips-1.0.7.jar
```

Build and run:

```bash
docker build -t kafka-connect-snowflake:v4 .
docker run -d --name kafka-connect \
  -p 8083:8083 \
  -e CONNECT_BOOTSTRAP_SERVERS="kafka:29092" \
  -e CONNECT_REST_ADVERTISED_HOST_NAME="kafka-connect" \
  -e CONNECT_GROUP_ID="snowflake-connector-group" \
  -e CONNECT_CONFIG_STORAGE_TOPIC="_connect-configs" \
  -e CONNECT_OFFSET_STORAGE_TOPIC="_connect-offsets" \
  -e CONNECT_STATUS_STORAGE_TOPIC="_connect-status" \
  -e CONNECT_CONFIG_STORAGE_REPLICATION_FACTOR="1" \
  -e CONNECT_OFFSET_STORAGE_REPLICATION_FACTOR="1" \
  -e CONNECT_STATUS_STORAGE_REPLICATION_FACTOR="1" \
  -e CONNECT_KEY_CONVERTER="org.apache.kafka.connect.storage.StringConverter" \
  -e CONNECT_VALUE_CONVERTER="org.apache.kafka.connect.json.JsonConverter" \
  -e CONNECT_VALUE_CONVERTER_SCHEMAS_ENABLE="false" \
  -e CONNECT_PLUGIN_PATH="/usr/share/java,/usr/share/confluent-hub-components" \
  kafka-connect-snowflake:v4
```

### 5.2 Verify Installation

Check that the HP v4.x connector is available:

```bash
curl -s http://localhost:8083/connector-plugins | \
  jq '.[] | select(.class | contains("Snowflake"))'
```

**Expected output:**
```json
{
  "class": "com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector",
  "type": "sink",
  "version": "4.0.0-rc8"
}
```

**Success Criteria:**
- [x] Class name includes `StreamingSinkConnector` (with "Streaming")
- [x] Version shows 4.0.0-rc8 or later v4.x
- [x] No `NoClassDefFoundError` in Kafka Connect logs

---

## 6. Connector Configuration

*Estimated time: 10 minutes*

### 6.1 Minimal Working Configuration

Create `connector.json`:

```json
{
  "name": "snowflake-sink-payments",
  "config": {
    "connector.class": "com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector",
    "tasks.max": "1",

    "topics": "payments.auth",

    "snowflake.url.name": "orgname-accountname.snowflakecomputing.com:443",
    "snowflake.user.name": "KAFKA_INGEST_USER",
    "snowflake.private.key": "<FULL_PKCS8_PEM_CONTENT>",
    "snowflake.role.name": "PAYMENTS_INGEST_ROLE",
    "snowflake.database.name": "PAYMENTS_DB",
    "snowflake.schema.name": "RAW",

    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",

    "errors.tolerance": "none",
    "errors.log.enable": "true"
  }
}
```

### 6.2 Add Metadata Capture

Add these fields to populate `SOURCE_TOPIC`, `SOURCE_PARTITION`, `SOURCE_OFFSET`:

```json
"snowflake.metadata.topic": "true",
"snowflake.metadata.offset.and.partition": "true"
```

> ⚠️ **Critical:** Use dot-separated notation (`offset.and.partition`), NOT camelCase (`offsetAndPartition`).

### 6.3 Secure Configuration with Environment Variables

**Problem:** Hardcoded private keys are insecure and visible via REST API.

**Solution:** Use Kafka Connect's ConfigProvider for environment variable substitution.

**Step 1:** Enable ConfigProvider in docker-compose or environment:

```yaml
environment:
  CONNECT_CONFIG_PROVIDERS: "env"
  CONNECT_CONFIG_PROVIDERS_ENV_CLASS: "org.apache.kafka.common.config.provider.EnvVarConfigProvider"

  # Snowflake credentials
  SNOWFLAKE_URL: "orgname-accountname.snowflakecomputing.com:443"
  SNOWFLAKE_USER: "KAFKA_INGEST_USER"
  SNOWFLAKE_PRIVATE_KEY: "<FULL_PKCS8_PEM_CONTENT>"
```

**Step 2:** Use `${env:}` syntax in connector config:

```json
"snowflake.url.name": "${env:SNOWFLAKE_URL}",
"snowflake.user.name": "${env:SNOWFLAKE_USER}",
"snowflake.private.key": "${env:SNOWFLAKE_PRIVATE_KEY}"
```

**Step 3:** Recreate container (restart is insufficient):

```bash
docker-compose stop kafka-connect
docker-compose rm -f kafka-connect
docker-compose up -d kafka-connect
```

**Verification:**

```bash
curl -s http://localhost:8083/connectors/snowflake-sink-payments/config | \
  jq -r '."snowflake.private.key"'
# Should output: ${env:SNOWFLAKE_PRIVATE_KEY} (not the actual key)
```

### 6.4 Configuration Reference

| Field | Required | Description | Notes |
|-------|----------|-------------|-------|
| `connector.class` | YES | Must be `SnowflakeStreamingSinkConnector` | Not `SinkConnector` (v3.x) |
| `tasks.max` | YES | Number of parallel tasks | Set ≤ topic partition count |
| `topics` | YES | Comma-separated topic list | Use `topic2table.map` for multiple topics |
| `snowflake.url.name` | YES | Account URL | Format: `org-account.snowflakecomputing.com:443` |
| `snowflake.user.name` | YES | Service account username | |
| `snowflake.private.key` | YES | PKCS8 PEM private key | Full content with headers |
| `snowflake.role.name` | YES | Connector role | Must have required grants |
| `snowflake.database.name` | YES | Target database | |
| `snowflake.schema.name` | YES | Target schema | |
| `snowflake.metadata.topic` | No | Populate `SOURCE_TOPIC` | Set to `"true"` |
| `snowflake.metadata.offset.and.partition` | No | Populate offset/partition | Dot-separated (not camelCase) |
| `errors.tolerance` | No | Error handling | `"none"` (fail fast) or `"all"` (skip errors) |

---

## 7. Deploying the Connector

*Estimated time: 5 minutes*

### 7.1 Create Connector

```bash
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d @connector.json
```

**Success response:**
```json
{
  "name": "snowflake-sink-payments",
  "config": { ... },
  "tasks": [],
  "type": "sink"
}
```

### 7.2 Check Connector Status

```bash
curl -s http://localhost:8083/connectors/snowflake-sink-payments/status | jq
```

**Healthy output:**
```json
{
  "name": "snowflake-sink-payments",
  "connector": {
    "state": "RUNNING",
    "worker_id": "kafka-connect:8083"
  },
  "tasks": [
    {
      "id": 0,
      "state": "RUNNING",
      "worker_id": "kafka-connect:8083"
    }
  ],
  "type": "sink"
}
```

### 7.3 If Connector Shows FAILED

Check logs for errors:

```bash
docker logs kafka-connect --tail 100 | grep -i error
```

**Common Errors:**

| Error Message | Cause | Fix |
|---------------|-------|-----|
| `NoClassDefFoundError: BouncyCastleFipsProvider` | Missing BC-FIPS JARs | Rebuild with correct Dockerfile (Section 5.1) |
| `Invalid Snowflake URL` | Malformed URL format | Use `org-account.snowflakecomputing.com:443` |
| `Authentication failed` | Wrong private key or user | Verify key-pair auth setup (Section 3.4) |
| `ERR_PIPE_DOES_NOT_EXIST_OR_NOT_AUTHORIZED` | Missing OPERATE privilege | Grant OPERATE on pipe (Section 3.5) |
| `Insufficient privileges` | Missing table/schema grants | Verify all grants (Section 3.5) |

---

## 8. End-to-End Verification

*Estimated time: 10 minutes*

### 8.1 Produce Test Messages

Send a test JSON event to your Kafka topic:

```bash
kafka-console-producer --bootstrap-server localhost:9092 --topic payments.auth
```

Paste this sample event and press Enter:

```json
{"env":"dev","event_ts":"2024-03-31T16:30:00Z","event_id":"test-001","payment_id":"PAY-ABC123","merchant_id":"MERCH-001","merchant_name":"Test Store","region":"NA","country":"US","card_brand":"VISA","issuer_bin":"411111","payment_method":"CREDIT","amount":99.99,"currency":"USD","auth_status":"APPROVED","decline_code":null,"auth_latency_ms":120}
```

### 8.2 Wait for Ingestion

HP Connector typically delivers data within **5-10 seconds**. Wait 15 seconds to be safe.

### 8.3 Verify Data in Snowflake

```sql
-- Check row count
SELECT COUNT(*) FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW;
-- Should show at least 1 row

-- View most recent records
SELECT
    event_id,
    auth_status,
    amount,
    source_topic,
    source_partition,
    source_offset,
    ingested_at
FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW
ORDER BY ingested_at DESC
LIMIT 5;
```

### 8.4 Monitor Ongoing Ingestion

```sql
-- Events per minute for last 5 minutes
SELECT
    DATE_TRUNC('minute', ingested_at) AS minute,
    COUNT(*) AS event_count
FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW
WHERE ingested_at >= DATEADD(minute, -5, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY 1 DESC;
```

### 8.5 Check Connector Metrics

```bash
curl -s http://localhost:8083/connectors/snowflake-sink-payments/status | \
  jq '.tasks[] | {id, state, worker_id}'
```

**Success Criteria:**
- [x] Row count increases after producing messages
- [x] Test event appears in query results
- [x] `SOURCE_TOPIC` shows `payments.auth` (if metadata enabled)
- [x] `SOURCE_PARTITION` shows `0` or higher
- [x] `SOURCE_OFFSET` shows incrementing numbers
- [x] `INGESTED_AT` timestamp is recent (within 1 minute)
- [x] Connector status shows all tasks `RUNNING`

---

## 9. Troubleshooting Guide

Organized by observable symptom for fast diagnosis.

### Symptom 1: Connector RUNNING but 0 Rows in Snowflake

**Diagnostic:**

```bash
# Check connector class
curl -s http://localhost:8083/connectors/snowflake-sink-payments/config | \
  jq -r '."connector.class"'
# Should output: SnowflakeStreamingSinkConnector (with "Streaming")

# Check for messages in topic
kafka-console-consumer --bootstrap-server localhost:9092 \
  --topic payments.auth --from-beginning --max-messages 1 --timeout-ms 5000
```

**Possible Causes:**

1. **Wrong connector class (v3.x instead of v4.x)**
   - Fix: Delete connector, update config to use `SnowflakeStreamingSinkConnector`, recreate

2. **No messages in Kafka topic**
   - Fix: Start producing messages to the topic

3. **User-defined pipe misconfigured**
   - Check: `SHOW PIPES; SELECT GET_DDL('PIPE', 'PAYMENTS_DB.RAW.AUTH_EVENTS_RAW');`
   - Fix: Recreate pipe with name matching table (Section 3.3)

### Symptom 2: Metadata Columns Are NULL

**Diagnostic:**

```sql
SELECT source_topic, source_partition, source_offset
FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW LIMIT 1;
-- If all NULL, metadata not being captured
```

**Possible Causes:**

1. **Wrong metadata config keys (v3.x camelCase)**
   ```bash
   curl -s http://localhost:8083/connectors/snowflake-sink-payments/config | \
     jq -r '."snowflake.metadata.offset.and.partition"'
   # Should output: true (not null)
   ```
   - Fix: Update config with dot-separated keys (Section 6.2)

2. **Pipe doesn't extract RECORD_METADATA**
   ```sql
   SELECT GET_DDL('PIPE', 'PAYMENTS_DB.RAW.AUTH_EVENTS_RAW');
   -- Check for $1:RECORD_METADATA:topic/partition/offset
   ```
   - Fix: Recreate pipe with RECORD_METADATA extraction (Section 3.3)

### Symptom 3: ERR_PIPE_DOES_NOT_EXIST_OR_NOT_AUTHORIZED

**Diagnostic:**

```sql
-- Check pipe exists
SHOW PIPES LIKE 'AUTH_EVENTS_RAW' IN SCHEMA PAYMENTS_DB.RAW;

-- Check privileges
SHOW GRANTS ON PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW;
-- Must include OPERATE (not just MONITOR)
```

**Fix:**

```sql
-- Grant OPERATE privilege
GRANT OPERATE ON PIPE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;

-- Also ensure SELECT on table
GRANT SELECT ON TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_INGEST_ROLE;
```

Restart connector:

```bash
curl -X POST http://localhost:8083/connectors/snowflake-sink-payments/restart
```

### Symptom 4: Multiple Tasks FAILED, Connector RUNNING

**Diagnostic:**

```bash
# Check topic partition count
kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --topic payments.auth | grep PartitionCount

# Check tasks.max
curl -s http://localhost:8083/connectors/snowflake-sink-payments/config | \
  jq -r '."tasks.max"'
```

**Fix:**

Set `tasks.max` ≤ partition count:

```bash
# Update config
curl -X PUT http://localhost:8083/connectors/snowflake-sink-payments/config \
  -H "Content-Type: application/json" \
  -d '{
    "tasks.max": "1",
    ... (include all other required fields)
  }'
```

Or increase topic partitions:

```bash
kafka-topics.sh --bootstrap-server localhost:9092 \
  --alter --topic payments.auth --partitions 24
```

### Symptom 5: HTTP 500 When Creating Connector

**Diagnostic:**

```bash
docker logs kafka-connect --tail 100 | grep -i "NoClassDefFoundError"
```

**Fix:**

Rebuild Kafka Connect container with Bouncy Castle FIPS JARs (Section 5.1).

### Symptom 6: Slow Ingestion (Minutes Instead of Seconds)

**Possible Causes:**

1. **Using v3.x batch connector** - Verify class name includes "Streaming"
2. **Network latency** - Check connectivity between Kafka Connect and Snowflake
3. **Large batches** - Check connector buffer settings

---

## 10. Operating the Connector

### Viewing Configuration

```bash
curl -s http://localhost:8083/connectors/snowflake-sink-payments/config | jq
```

### Restarting Connector

```bash
# Restart entire connector
curl -X POST http://localhost:8083/connectors/snowflake-sink-payments/restart

# Restart single task
curl -X POST http://localhost:8083/connectors/snowflake-sink-payments/tasks/0/restart
```

### Updating Configuration

```bash
curl -X PUT http://localhost:8083/connectors/snowflake-sink-payments/config \
  -H "Content-Type: application/json" \
  -d @connector.json
```

### Pausing and Resuming

```bash
# Pause (stops consuming from Kafka, preserves offsets)
curl -X PUT http://localhost:8083/connectors/snowflake-sink-payments/pause

# Resume
curl -X PUT http://localhost:8083/connectors/snowflake-sink-payments/resume
```

### Deleting Connector

```bash
curl -X DELETE http://localhost:8083/connectors/snowflake-sink-payments
```

### Monitoring Snowflake Ingestion

```sql
-- Recent ingestion activity
SELECT
    DATE_TRUNC('minute', ingested_at) AS minute,
    COUNT(*) AS events
FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW
WHERE ingested_at >= DATEADD(hour, -1, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY 1 DESC;

-- Check pipe status
SHOW PIPES LIKE 'AUTH_EVENTS_RAW' IN SCHEMA PAYMENTS_DB.RAW;
```

### Checking Consumer Lag

```bash
kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --group connect-snowflake-sink-payments \
  --describe
```

**Healthy:** LAG = 0 or small number
**Problem:** LAG growing continuously

---

## 11. Performance Tuning (Optional)

### Scaling with Multiple Tasks

Increase `tasks.max` when:
- Consumer lag is growing
- Single task can't keep up with topic throughput
- You want parallel processing

**Guidelines:**
- Start at 1, increase if lagging
- Set `tasks.max` ≤ topic partition count
- Monitor Kafka Connect worker resources (CPU, memory)

### Kafka Producer Optimization

Recommended producer settings for high throughput:

```python
{
    "bootstrap.servers": "kafka:29092",
    "compression.type": "zstd",
    "acks": "all",
    "linger.ms": 10,          # Increase for better batching
    "batch.size": 32768,      # 32KB batches
    "buffer.memory": 67108864, # 64MB buffer
}
```

### Topic Configuration

```bash
kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name payments.auth \
  --alter --add-config \
    compression.type=zstd,\
    max.message.bytes=10485760
```

---

## 12. Next Steps & Resources

### Extending Your Setup

**Add More Topics:**

```json
"topics": "topic1,topic2,topic3"
```

**Multi-Table Mapping:**

```json
"snowflake.topic2table.map": "payments.auth:AUTH_EVENTS_RAW,payments.settlement:SETTLEMENT_EVENTS_RAW"
```

### Production Hardening Checklist

- [ ] Enable TLS/SSL for Kafka connections
- [ ] Use secret management (Vault, AWS Secrets Manager) for credentials
- [ ] Configure monitoring/alerting on connector status
- [ ] Set up disaster recovery (backup consumer group offsets)
- [ ] Document runbooks for common operational scenarios
- [ ] Implement dead letter queue (DLQ) for poison messages
- [ ] Test schema evolution scenarios
- [ ] Configure appropriate `errors.tolerance` for production

### Official Documentation

- [Snowflake HP Kafka Connector](https://docs.snowflake.com/en/user-guide/kafka-connector)
- [Kafka Connect REST API](https://docs.confluent.io/platform/current/connect/references/restapi.html)
- [Snowpipe Streaming](https://docs.snowflake.com/en/user-guide/data-load-snowpipe-streaming)

### Project-Specific Skills

For deeper reference patterns specific to this project:

- `.claude/skills/kafka-connect-snowflake/SKILL.md` - HP Connector v4.x patterns and pitfalls
- `.claude/skills/kafka-producer-python/SKILL.md` - Python producer setup and Docker networking
- `docs/DEPLOY_TROUBLESHOOTING.md` - Complete deployment troubleshooting log (Issues 19-25)

---

**🎉 Congratulations!** You now have a working HP Kafka Connector streaming data into Snowflake with 5-10 second latency.
