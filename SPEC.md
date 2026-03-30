# Payment Authorization Command Center — Technical Specification

**Version:** 1.0
**Date:** 2026-03-30
**Status:** Draft

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Architecture](#2-architecture)
3. [Component Specifications](#3-component-specifications)
4. [Dashboard Screens](#4-dashboard-screens)
5. [API Contract](#5-api-contract)
6. [Environment Model](#6-environment-model)
7. [Change Management Toolchain](#7-change-management-toolchain)
8. [Repository Structure](#8-repository-structure)
9. [Constraints and Risks](#9-constraints-and-risks)
10. [References](#10-references)

---

## 1. Project Overview

### 1.1 Name

Payment Authorization Command Center

### 1.2 Purpose

A real-time operational dashboard for payment authorization monitoring. Kafka-originated card-authorization events stream into Snowflake via Snowpipe Streaming high-performance architecture. Operations users observe approval rates, decline rates, and authorization latency moving in near real-time, then drill into merchant, region, issuer BIN, card brand, decline code, and recent failed transactions from a React application running in Snowpark Container Services (SPCS).

### 1.3 Target Audience

- **Platform engineering teams** evaluating Snowflake's streaming ingest, interactive tables, and SPCS capabilities.
- **Payment operations teams** needing sub-minute visibility into authorization health.
- **Demo audiences** where the system must feel production-credible rather than synthetic.

### 1.4 Demo Narrative

1. A containerized event generator produces realistic card-authorization traffic into a single shared Kafka topic, tagging each event with an `env` field (dev, preprod, or prod).
2. A Kafka Connect cluster running the Snowflake High Performance Kafka connector ingests all events into a shared Snowflake raw landing table via Snowpipe Streaming HP with 5-10 second ingest-to-query latency.
3. Interactive tables (with 60-second TARGET_LAG) aggregate and serve the data with a 60-second refresh cadence, filtering and grouping by `env` as needed.
4. An interactive warehouse provides low-latency query serving for the dashboard.
5. The SPCS-hosted React + Python application renders live KPIs, time series, breakdowns, and drill-downs with environment filtering as a logical dimension alongside merchant, region, and other business dimensions.
6. The operator triggers a scenario (issuer outage, merchant decline spike, latency regression) and the dashboard reflects the incident within ~60 seconds across the selected environment filter.

### 1.5 V1 Scope and Non-Goals

**In Scope:**

- Real-time monitoring dashboard with sub-minute serving latency
- Multi-environment visibility (dev, preprod, prod) within a single Snowflake account
- Scenario-driven incident injection for demo purposes
- Interactive tables and warehouses for low-latency serving
- Synthetic data generation only (no real payment data)

**Out of Scope for V1:**

- Late-arriving or heavily out-of-order event handling (assumes timely event arrival)
- Viewer authentication/authorization workflows for external users (demo viewers are passive observers)
- Multi-account federation (all environments share one Snowflake account)
- Cross-region replication or disaster recovery
- Real cardholder data or PCI-compliant data handling

### 1.6 Key Architectural Decisions

**1. Do not put dynamic tables in the hot path of the live dashboard.**

Dynamic tables and interactive tables both have a minimum 60-second target lag. Stacking dynamic tables in front of interactive tables doubles the latency budget. Interactive tables are not ingest sinks; they are optimized serving structures that support only INSERT OVERWRITE DML.

The clean pattern is:

```
Kafka (shared topic) -> Kafka Connect (HP connector) -> shared raw table -> interactive tables with TARGET_LAG (live serving)
```

Dynamic tables are used in a parallel curated path for enrichment, longer retention, and broader BI/ML use — not in the live dashboard's critical path.

**2. Model environments as data, not as separate ingest streams.**

This demo uses a single Kafka topic and a single raw landing table. The `env` field in each event provides logical environment separation. This design:
- Reduces operational overhead (one ingest pipeline vs three)
- Simplifies Kafka Connect configuration (one connector targeting one database/schema)
- Enables unified cross-environment dashboards without database switching
- Maintains demo simplicity while illustrating production patterns through governance and monitoring

**Production Note:** In a production system, environments would use separate Kafka topics (`payments.dev.auth`, `payments.preprod.auth`, `payments.prod.auth`) for blast-radius isolation, independent offset management, and per-environment access control. The shared-topic model is a deliberate demo simplification.

**Primary vs fallback ingest path:**

- **Primary:** Kafka Connect with the Snowflake High Performance connector (v4.x, preview).
- **Fallback:** Python relay using `snowflake-connector-python` for batch inserts if Kafka Connect preview access or runtime behavior blocks the demo. Expect ~1-3 minute ingest latency on the fallback path.

---

## 2. Architecture

### 2.1 Data Flow

```text
┌─────────────────┐
│ Event Generator  │  Python container (Faker-based)
│ (scenarios:      │  Control API for incident injection
│  baseline,       │  Tags all events with env field
│  issuer_outage,  │
│  decline_spike,  │
│  latency_spike)  │
└────────┬────────┘
         │ Kafka Producer
         ▼
┌─────────────────┐
│ Shared Kafka     │  payments.auth (single topic)
│ Topic            │  All envs (dev, preprod, prod)
│                  │  Partitioned by merchant_id hash
└────────┬────────┘
         │ Kafka Connect cluster
         │ Snowflake HP connector (primary path)
         ▼
┌──────────────────────────────────────────────────────────────────────┐
│                        SNOWFLAKE ACCOUNT                            │
│                                                                     │
│  ┌──────────────────────────────────┐                               │
│  │  PAYMENTS_DB.RAW.AUTH_EVENTS_RAW │  Standard table               │
│  │  (shared landing table)           │  Snowpipe Streaming HP target │
│  │  (all envs, filtered by env col) │                               │
│  └──────────┬───────────────────────┘                               │
│             │                                                       │
│       ┌─────┴──────────────────┐                                    │
│       │                        │                                    │
│       ▼                        ▼                                    │
│  ┌─────────────────┐   ┌───────────────────────┐                   │
│  │ SERVE.IT_AUTH_   │   │ SERVE.IT_AUTH_         │                  │
│  │ MINUTE_METRICS   │   │ EVENT_SEARCH           │                  │
│  │ (interactive     │   │ (interactive table)    │                  │
│  │  table, 60s lag) │   │ 60s lag, last 60 min)  │                  │
│  │  (env in grain)  │   │ (env in row)           │                  │
│  └────────┬────────┘   └──────────┬─────────────┘                  │
│           │                       │                                 │
│           └───────────┬───────────┘                                 │
│                       ▼                                             │
│              ┌─────────────────┐                                    │
│              │ Interactive WH   │  XSMALL, AUTO_SUSPEND=86400       │
│              │ (query serving)  │  Dashboard filters by env         │
│              └────────┬────────┘                                    │
│                       │                                             │
│                       ▼                                             │
│              ┌─────────────────┐                                    │
│              │  SPCS Service    │  React UI + Python API            │
│              │  (public endpt)  │  Compute pool: CPU_X64_S          │
│              │  Cross-env view  │  Filters by env dimension         │
│              └─────────────────┘                                    │
│                                                                     │
│  ── Parallel curated path (not hot path) ──                         │
│                                                                     │
│  RAW.AUTH_EVENTS_RAW (shared)                                       │
│       │                                                             │
│       ▼                                                             │
│  ┌─────────────────────────┐                                        │
│  │ CURATED.DT_AUTH_ENRICHED│  Dynamic table (dbt-managed)           │
│  │ CURATED.DT_AUTH_HOURLY  │  Standard warehouse refresh            │
│  │ CURATED.DT_AUTH_DAILY   │  For BI, ML, longer retention          │
│  │ (env in grain)          │  Filters raw by env if needed          │
│  └─────────────────────────┘                                        │
└──────────────────────────────────────────────────────────────────────┘
```

### 2.2 Component Inventory

| Component | Technology | Purpose |
|---|---|---|
| Event Generator | Python, Faker, FastAPI | Produce realistic auth events; scenario injection; tags all events with `env` |
| Kafka | Apache Kafka (self-managed or Confluent) | Shared message bus (single topic, all environments) |
| Kafka Connect Cluster | Kafka Connect + Snowflake HP connector | Primary ingest into Snowflake (one connector, one target) |
| Fallback Ingest Relay | Python + snowflake-connector-python | Backup batch ingest path for demo continuity (~1-3 min latency) |
| Landing Table | Snowflake standard table | Shared raw event storage (all environments) |
| Live Serving Tables | Interactive tables (with TARGET_LAG) | Pre-aggregated metrics + recent event search (env in grain) |
| Interactive Warehouse | Snowflake interactive warehouse | Low-latency query serving |
| Standard Warehouse | Snowflake standard warehouse | IT refresh, DT refresh, admin |
| Curated Path | dbt + dynamic tables | Enrichment, hourly/daily rollups |
| Dashboard | React + Python (FastAPI), SPCS | Operational UI with env filtering |
| Infrastructure | Terraform | Account scaffolding |
| DDL Migrations | schemachange | Tables, interactive tables, policies, service SQL |
| CI/CD | GitHub Actions + Snowflake CLI | Build, test, deploy |

---

## 3. Component Specifications

### 3.1 Event Generator

**Runtime:** Python 3.11+ container (Docker)

**Dependencies:** `confluent-kafka`, `faker`, `fastapi`, `uvicorn`

**Kafka Producer Configuration:**

| Setting | Value |
|---|---|
| `bootstrap.servers` | Per environment |
| `acks` | `all` |
| `linger.ms` | `5` |
| `batch.size` | `16384` |
| `compression.type` | `zstd` |
| `key.serializer` | String (merchant_id for partition affinity) |
| `value.serializer` | JSON |

**Event Schema (JSON):**

```json
{
  "env": "prod",
  "event_ts": "2026-03-30T16:30:00.123Z",
  "event_id": "evt-a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "payment_id": "pay-11223344-5566-7788-99aa-bbccddeeff00",
  "merchant_id": "merch-0042",
  "merchant_name": "Acme Electronics",
  "region": "NA",
  "country": "US",
  "card_brand": "VISA",
  "issuer_bin": "411111",
  "payment_method": "CREDIT",
  "amount": 149.99,
  "currency": "USD",
  "auth_status": "APPROVED",
  "decline_code": null,
  "auth_latency_ms": 87
}
```

**Scenario Profiles:**

| Profile | Behavior |
|---|---|
| `baseline` | Normal distribution: ~95% approval, 50-150ms latency, uniform merchant/region spread |
| `issuer_outage` | BIN range `4111xx` drops to 10% approval, decline_code = `ISSUER_UNAVAILABLE` |
| `merchant_decline_spike` | Specific merchant_id sees 60% decline rate, decline_code = `DO_NOT_HONOR` |
| `latency_spike` | Region `EU` latency jumps to 800-2000ms, approval rate stays normal |

**Control API:**

| Endpoint | Method | Body | Description |
|---|---|---|---|
| `/status` | GET | — | Current scenario, events/sec, uptime |
| `/scenario` | POST | `{"profile": "issuer_outage", "duration_sec": 300}` | Activate scenario for duration |
| `/scenario` | DELETE | — | Return to baseline |
| `/rate` | POST | `{"events_per_sec": 500}` | Adjust throughput |

**Deterministic Seeds:** Each scenario profile accepts an optional `seed` parameter so identical event sequences can be replayed across dev, preprod, and prod-like test runs.

### 3.2 Kafka Topology

**Topic:**

| Topic | Purpose | Partitions | Retention |
|---|---|---|
| `payments.auth` | All environments (dev, preprod, prod) | 24 | 72h |

**Partitioning:** Key = `merchant_id` (ensures all events for a merchant land on the same partition for ordered processing).

**Environment Separation:** Logical only. Each event carries an `env` field with value `dev`, `preprod`, or `prod`. The shared topic contains all three environments' traffic.

**Primary Consumer Group:** `snowflake-hp-sink-payments`

**Throughput Design:**

- Partition count (24) is sized for combined throughput across all environments.
- Baseline: ~500-1000 events/sec combined.
- Peak scenario traffic: up to 2000 events/sec.
- If environment isolation becomes a runtime concern (noisy neighbor, per-env lag), consider adding secondary env-specific topics as a fallback or using Kafka partitioning strategies that allocate partition ranges by env.

**Connector Deployment Model:**

One Kafka Connect connector configuration targets:
- Topic: `payments.auth`
- Snowflake target: `PAYMENTS_DB.RAW.AUTH_EVENTS_RAW`

The connector uses `snowflake.topic2table.map` to route the single topic to the landing table.

**Kafka Connect Operational Notes:**

- Deploy Kafka Connect in the same cloud provider region as the Snowflake account to reduce latency and improve throughput.
- Size Kafka Connect memory based on partition count; Snowflake recommends at least 5 MB RAM per Kafka partition on Connect nodes (minimum ~120 MB for 24 partitions).
- Set `tasks.max` close to partition count (24) without exceeding practical CPU limits on the Kafka Connect cluster.
- Externalize the Snowflake private key and related connector secrets using a secrets manager or Kafka Connect ConfigProvider rather than storing them directly in version-controlled config files.

### 3.3 Ingest Layer — Snowpipe Streaming HP

#### 3.3.1 Primary Path: Kafka Connect with Snowflake HP Connector

**Status:** Public Preview as of Dec 17, 2025. Not available for production use. Available only to selected accounts.

This spec treats the Snowflake High Performance Kafka connector as the **primary path** for the demo. It provides a Kafka-native operating model without custom bridge code.

**Connector Design Principles:**

- One connector config for the shared topic.
- Use Snowpipe Streaming high-performance ingestion.
- Preserve Kafka lineage metadata (`topic`, `partition`, `offset`) in the landing table.
- Keep message values JSON-based for the demo.
- Tune `tasks.max` by partition count and available Kafka Connect CPU.

**Connector configuration:**

```properties
connector.class=com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector
name=auth-events-sink-payments
tasks.max=24
topics=payments.auth
snowflake.topic2table.map=payments.auth:AUTH_EVENTS_RAW
snowflake.url.name=<account>.snowflakecomputing.com:443
snowflake.user.name=KAFKA_INGEST_USER
snowflake.role.name=KAFKA_INGEST_ROLE
snowflake.private.key=<private_key_material_or_externalized_secret>
snowflake.database.name=PAYMENTS_DB
snowflake.schema.name=RAW
value.converter=org.apache.kafka.connect.json.JsonConverter
value.converter.schemas.enable=false
key.converter=org.apache.kafka.connect.storage.StringConverter
errors.log.enable=true
errors.tolerance=none
snowflake.metadata.topic=true
snowflake.metadata.offsetAndPartition=true
```

**Configuration Notes:**

- **No warehouse property:** Snowpipe Streaming HP is serverless. It charges streaming ingest compute credits per uncompressed GB, not warehouse credits. There is no `snowflake.warehouse.name` property in the v4.x connector.
- **No `snowflake.ingestion.method`:** The v4.x connector only supports streaming ingest. The legacy `SNOWPIPE` mode was removed entirely, making this property unnecessary.
- **Metadata columns:** `snowflake.metadata.topic=true` and `snowflake.metadata.offsetAndPartition=true` explicitly enable Kafka lineage columns (`source_topic`, `source_partition`, `source_offset`) in the landing table. Without these, the metadata columns will not be populated.
- **Schematization:** The v4.x connector defaults to schematization enabled, mapping JSON fields to individual typed columns. JSON field names are matched to Snowflake column names case-insensitively by default, but verify column name alignment during development.

**Pipe Behavior:**

The Snowpipe Streaming HP architecture uses PIPE objects internally, but Snowflake **auto-creates a default streaming pipe** for each target table on demand. Explicit `CREATE PIPE` is needed only for transformations or pre-clustering, which this demo does not require. This differs from the classic Snowpipe Streaming architecture, which does not use PIPE objects at all. Reference: [Getting Started with Snowpipe Streaming V2](https://www.snowflake.com/en/developers/guides/getting-started-with-snowpipe-streaming-v2/#overview).

**Recovery Model:**

1. Kafka Connect tracks offsets through the Kafka Connect framework.
2. The Snowflake connector preserves Kafka topic, partition, and offset metadata for lineage and replay diagnostics.
3. Connector restarts resume from Kafka Connect-managed offsets.
4. If connector preview limitations or runtime instability threaten the demo, cut over to the Python batch fallback path (expect ~1-3 min ingest latency).

**Error Handling:**

- Connector errors are logged through Kafka Connect and surfaced in worker logs/REST status.
- Schema mismatch or malformed JSON routes the record to error logs and blocks ingestion until corrected.
- Tombstone/null record behavior must be explicitly configured if introduced later; V1 event payloads are non-null JSON.

#### 3.3.2 Fallback Path: Python Ingest Relay with Snowflake Connector

If the HP Kafka connector is unavailable, unstable, or blocked by preview access constraints, the backup plan is a lightweight Python relay that:

1. consumes from the shared `payments.auth` topic,
2. batches rows in memory (e.g., 1000 rows or 5 seconds, whichever comes first),
3. writes rows into `PAYMENTS_DB.RAW.AUTH_EVENTS_RAW` using `snowflake-connector-python` with `write_pandas()`,
4. preserves Kafka lineage columns (`source_topic`, `source_partition`, `source_offset`) for deduplication and replay analysis.

**Fallback design intent:**

- Keep the dashboard demo viable without redesigning the downstream serving model.
- Use the same landing-table schema as the Kafka Connect path.
- Keep the fallback focused on reliability and simplicity, not lowest-possible ingest latency.

**Latency trade-off:** This fallback performs batch `PUT` + `COPY INTO` (via internal stage), **not** Snowpipe Streaming. Expected ingest-to-query latency is **1-3 minutes** (vs ~10 seconds for the primary HP connector path). This is acceptable for demo continuity but the dashboard freshness widget will show noticeably higher lag.

**Why not ADBC?** The ADBC Snowflake driver uses the same batch `PUT` + `COPY INTO` mechanism as `write_pandas()` with equivalent performance, but requires a Go driver dependency and has a smaller community. The `snowflake-connector-python` is better documented and more widely supported. **Why not Snowpipe Streaming SDK?** The Snowpipe Streaming Ingest SDK is Java-only and would require changing the language stack.

**Connection pattern:**

```python
import snowflake.connector
import pandas as pd

conn = snowflake.connector.connect(
    account="<account>",
    database="PAYMENTS_DB",
    schema="RAW",
    warehouse="PAYMENTS_ADMIN_WH",
    role="KAFKA_INGEST_ROLE",
    user="KAFKA_INGEST_USER",
    private_key_file="/path/to/rsa_key.p8"
)

# Batch write using write_pandas (PUT + COPY INTO)
from snowflake.connector.pandas_tools import write_pandas
write_pandas(conn, df, "AUTH_EVENTS_RAW")
```

Reference: [Snowflake Connector for Python](https://docs.snowflake.com/en/developer-guide/python-connector/python-connector-pandas).

#### 3.3.3 Decision

- **Primary:** Kafka Connect + Snowflake HP Kafka connector (one shared topic, one connector). ~10s ingest latency.
- **Fallback:** Python ingest relay using `snowflake-connector-python` (same topic, same target table). ~1-3 min ingest latency.
- **Operational advantage:** Single ingest pipeline reduces config sprawl and simplifies monitoring compared to three per-env pipelines.

### 3.4 Landing Table

**Table Definition (shared across all environments):**

```sql
-- Shared raw landing table for all environments
CREATE OR REPLACE TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW (
    env                 VARCHAR(16)      NOT NULL   COMMENT 'Environment: dev, preprod, prod',
    event_ts            TIMESTAMP_NTZ    NOT NULL   COMMENT 'Event timestamp from source system',
    event_id            VARCHAR(64)      NOT NULL   COMMENT 'Unique event identifier (UUID) - business deduplication key within env',
    payment_id          VARCHAR(64)      NOT NULL   COMMENT 'Payment transaction identifier (synthetic/tokenized only)',
    merchant_id         VARCHAR(32)      NOT NULL   COMMENT 'Merchant identifier',
    merchant_name       VARCHAR(256)                COMMENT 'Merchant display name',
    region              VARCHAR(8)       NOT NULL   COMMENT 'Geographic region code (NA, EU, APAC, LATAM)',
    country             VARCHAR(4)       NOT NULL   COMMENT 'ISO 3166-1 alpha-2 country code',
    card_brand          VARCHAR(16)      NOT NULL   COMMENT 'Card network (VISA, MASTERCARD, AMEX, DISCOVER)',
    issuer_bin          VARCHAR(8)       NOT NULL   COMMENT 'Issuer Bank Identification Number (first 6-8 digits, synthetic)',
    payment_method      VARCHAR(16)      NOT NULL   COMMENT 'Payment method (CREDIT, DEBIT, PREPAID)',
    amount              NUMBER(12,2)     NOT NULL   COMMENT 'Transaction amount',
    currency            VARCHAR(4)       NOT NULL   COMMENT 'ISO 4217 currency code',
    auth_status         VARCHAR(16)      NOT NULL   COMMENT 'Authorization result (APPROVED, DECLINED, ERROR, TIMEOUT)',
    decline_code        VARCHAR(32)                 COMMENT 'Decline reason code (null if approved)',
    auth_latency_ms     INTEGER          NOT NULL   COMMENT 'Authorization round-trip latency in milliseconds',
    source_topic        VARCHAR(128)                COMMENT 'Originating Kafka topic name (populated by HP connector with snowflake.metadata.topic=true)',
    source_partition    INTEGER                     COMMENT 'Originating Kafka partition number (populated by HP connector with snowflake.metadata.offsetAndPartition=true)',
    source_offset       BIGINT                      COMMENT 'Originating Kafka offset (populated by HP connector with snowflake.metadata.offsetAndPartition=true)',
    headers             VARIANT                     COMMENT 'Kafka headers as key-value pairs',
    payload             VARIANT                     COMMENT 'Full original JSON payload for replay/debugging (synthetic data only)',
    ingested_at         TIMESTAMP_NTZ    NOT NULL
        DEFAULT CURRENT_TIMESTAMP()                 COMMENT 'Snowflake ingestion timestamp'
)
COMMENT = 'Shared raw landing table for card authorization events across all environments (SYNTHETIC DATA ONLY - NO REAL CARDHOLDER DATA)'
ENABLE_SCHEMA_EVOLUTION = FALSE
DATA_RETENTION_TIME_IN_DAYS = 14;
```

**Schema and Metadata Notes:**

- **`ENABLE_SCHEMA_EVOLUTION = FALSE`:** Schema evolution is disabled at the table level. The v4.x HP connector handles schema mapping independently via its schematization feature, mapping JSON fields to typed columns. This table-level setting prevents unintended schema drift from other ingest paths.
- **Kafka metadata columns:** The `source_topic`, `source_partition`, and `source_offset` columns are populated by the HP connector only when `snowflake.metadata.topic=true` and `snowflake.metadata.offsetAndPartition=true` are set in the connector config. Verify the exact column names produced by the connector match this schema during development.
- **Column name case:** The v4.x connector with schematization enabled matches JSON field names to Snowflake column names. Snowflake uppercases unquoted identifiers, so JSON field `merchant_id` maps to column `MERCHANT_ID`. Verify alignment during integration testing.

#### 3.4.1 Idempotency and Deduplication Contract

**Exactly-Once Guarantee:** Snowpipe Streaming high-performance (V2) reduces duplicate-ingest risk at the Snowflake ingestion layer. For this spec, the primary operational lineage comes from Kafka topic/partition/offset metadata preserved by the connector, while business-level deduplication still uses `event_id`.

**Business-Level Deduplication:**

- **Logical Key:** `(env, event_id)` is the composite deduplication key. The event generator assigns `event_id` uniquely within each environment. Since all environments share one raw table, the `env` field is required for deduplication scope.
- **Operational Key (primary path):** `(source_topic, source_partition, source_offset)` provides ingest-level lineage for replay diagnostics and gap detection. For the shared topic model, all events share `source_topic = 'payments.auth'`.
- **Raw Table Policy:** The landing table (`PAYMENTS_DB.RAW.AUTH_EVENTS_RAW`) is append-friendly and does not enforce deduplication at write time.
- **Serving Layer Deduplication:** Interactive tables and curated dynamic tables use `(env, event_id)` for deduplication when necessary. For minute-level metrics, duplicate events with the same `(env, event_id)` should be filtered using window functions or CTEs before aggregation.

**Late-Arriving Events (V1 Exclusion):**

V1 does not handle late-arriving or heavily out-of-order events. All queries and freshness calculations assume that `event_ts` is near-realtime and monotonically increasing within reasonable bounds. Future versions may add watermarking or late-arrival buffering logic.

**Deduplication Query Pattern (for serving layers):**

```sql
-- Example: Deduplicate by (env, event_id) before aggregation
WITH deduped_events AS (
    SELECT *
    FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW
    WHERE event_ts >= DATEADD('HOUR', -2, CURRENT_TIMESTAMP())
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY env, event_id 
        ORDER BY ingested_at DESC
    ) = 1
)
SELECT ...
FROM deduped_events;
```

**Gap Detection Query (Kafka lineage):**

```sql
SELECT
    source_topic,
    source_partition,
    source_offset,
    LAG(source_offset) OVER (
        PARTITION BY source_topic, source_partition
        ORDER BY source_offset
    ) AS previous_offset
FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW
QUALIFY source_offset != previous_offset + 1;
```

### 3.5 Data Classification and Display Policy

#### 3.5.1 Demo Data Classification

**All data in this system is synthetic and for demonstration purposes only.**

| Field Category | Policy | Rationale |
|---|---|---|
| **Payment Identifiers** | Synthetic UUIDs only. No real payment IDs. | `payment_id`, `event_id` are generated by the demo system and do not reference real transactions. |
| **Cardholder Data** | PROHIBITED. No PAN, CVV, cardholder name, email, or phone. | This is a demo system. Any PCI-sensitive fields are strictly forbidden. |
| **Issuer BIN** | Synthetic BINs only (e.g., `411111`, `555555`). | BINs in the demo use well-known test ranges. No real issuer BINs are stored. |
| **Merchant Information** | Fictional merchant names and IDs. | Merchant catalog is generated using `Faker` and does not reference real businesses. |
| **Transaction Amounts** | Synthetic values, uniformly distributed. | Amounts do not represent real transactions. |
| **Metadata (headers, payload)** | Contains only synthetic event data. | The `headers` and `payload` VARIANT columns store the full original event for replay/debugging but contain only synthetic data. |

#### 3.5.2 Display and Drill-Down Policy

**Dashboard Drill-Down Fields:**

The Recent Failures Panel and event drill-down modals expose the following fields to dashboard viewers:

| Field | Display | Sensitive? |
|---|---|---|
| `event_ts` | Yes | No |
| `event_id` | Yes | No (synthetic) |
| `payment_id` | Yes | No (synthetic) |
| `merchant_name` | Yes | No (fictional) |
| `merchant_id` | Yes | No (synthetic) |
| `region`, `country` | Yes | No |
| `card_brand` | Yes | No |
| `issuer_bin` | Yes | No (test BINs only) |
| `payment_method` | Yes | No |
| `amount`, `currency` | Yes | No (synthetic) |
| `auth_status` | Yes | No |
| `decline_code` | Yes | No |
| `auth_latency_ms` | Yes | No |
| `headers` | No | Excluded from UI (internal metadata only) |
| `payload` | No | Excluded from UI (internal replay only) |

**Masking Policy (Future Enhancement):**

V1 does not implement Snowflake masking policies since all data is synthetic. If this system were adapted for real data in the future, the following fields would require masking policies:

- `payment_id` → mask to last 4 characters
- `issuer_bin` → mask to first 4 digits
- `payload` → full redaction for non-admin roles

#### 3.5.3 Access Control

**Demo Viewer Access:**

- Demo viewers are passive observers and do not require direct Snowflake access.
- The SPCS public endpoint is accessible to Snowflake users in the same account who have been granted the `dashboard_viewer` service role.
- The dashboard application queries data using the service's owner role (`PAYMENTS_APP_ROLE`), which has SELECT privileges on all serving tables in the shared database.

**Operator Access:**

- Operators who run the event generator and trigger scenarios need access to the generator's control API but do not need Snowflake access.
- Operators with Snowflake access (e.g., for warm-up queries or troubleshooting) should use `PAYMENTS_OPS_ROLE`.

### 3.6 Live Serving Layer — Interactive Tables (with TARGET_LAG)

#### 3.5.1 Minute-Level Metrics

**Design Note:** This table is designed to support statistically correct aggregation. Latency metrics use sum and count columns so that weighted averages can be computed correctly when combining multiple minute buckets or filtering dimensions. Percentile calculations require access to raw event-level data and are served from the event search table.

```sql
-- Shared serving table for all environments
CREATE OR REPLACE INTERACTIVE TABLE PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS (
    event_minute            TIMESTAMP_NTZ,
    env                     VARCHAR(16),
    merchant_id             VARCHAR(32),
    merchant_name           VARCHAR(256),
    region                  VARCHAR(8),
    country                 VARCHAR(4),
    card_brand              VARCHAR(16),
    issuer_bin              VARCHAR(8),
    payment_method          VARCHAR(16),
    event_count             INTEGER,
    decline_count           INTEGER,
    approval_count          INTEGER,
    error_count             INTEGER,
    latency_sum_ms          BIGINT,
    latency_count           INTEGER,
    latency_0_50ms          INTEGER,
    latency_50_100ms        INTEGER,
    latency_100_200ms       INTEGER,
    latency_200_500ms       INTEGER,
    latency_500_1000ms      INTEGER,
    latency_1000ms_plus     INTEGER,
    total_amount            NUMBER(18,2),
    avg_amount              NUMBER(12,2)
)
    CLUSTER BY (event_minute, env, merchant_id, region)
    TARGET_LAG = '60 seconds'
    WAREHOUSE = PAYMENTS_REFRESH_WH
AS
WITH deduped_events AS (
    SELECT *
    FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW
    WHERE event_ts >= DATEADD('HOUR', -2, CURRENT_TIMESTAMP())
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY env, event_id 
        ORDER BY ingested_at DESC
    ) = 1
)
SELECT
    DATE_TRUNC('MINUTE', event_ts)          AS event_minute,
    env,
    merchant_id,
    merchant_name,
    region,
    country,
    card_brand,
    issuer_bin,
    payment_method,
    
    -- Event counts by status
    COUNT(*)                                AS event_count,
    COUNT_IF(auth_status = 'DECLINED')      AS decline_count,
    COUNT_IF(auth_status = 'APPROVED')      AS approval_count,
    COUNT_IF(auth_status IN ('ERROR', 'TIMEOUT'))
                                            AS error_count,
    
    -- Latency: sum and count for correct weighted average computation
    SUM(auth_latency_ms)                    AS latency_sum_ms,
    COUNT(*)                                AS latency_count,
    
    -- Latency histogram buckets for distribution analysis
    COUNT_IF(auth_latency_ms < 50)          AS latency_0_50ms,
    COUNT_IF(auth_latency_ms >= 50 AND auth_latency_ms < 100)
                                            AS latency_50_100ms,
    COUNT_IF(auth_latency_ms >= 100 AND auth_latency_ms < 200)
                                            AS latency_100_200ms,
    COUNT_IF(auth_latency_ms >= 200 AND auth_latency_ms < 500)
                                            AS latency_200_500ms,
    COUNT_IF(auth_latency_ms >= 500 AND auth_latency_ms < 1000)
                                            AS latency_500_1000ms,
    COUNT_IF(auth_latency_ms >= 1000)       AS latency_1000ms_plus,
    
    -- Amount aggregates
    SUM(amount)                             AS total_amount,
    AVG(amount)                             AS avg_amount
FROM deduped_events
GROUP BY ALL;
```

**Query Pattern for Weighted Average Latency:**

```sql
-- Correct weighted average across multiple minutes/dimensions
SELECT
    SUM(latency_sum_ms) / NULLIF(SUM(latency_count), 0) AS avg_latency_ms
FROM PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS
WHERE event_minute >= DATEADD('MINUTE', -15, CURRENT_TIMESTAMP())
  AND env = 'prod';
```

#### 3.5.2 Recent Event Search

This table provides event-level granularity for drill-downs and exact percentile calculations.

```sql
-- Shared serving table for all environments
CREATE OR REPLACE INTERACTIVE TABLE PAYMENTS_DB.SERVE.IT_AUTH_EVENT_SEARCH (
    event_ts            TIMESTAMP_NTZ,
    env                 VARCHAR(16),
    event_id            VARCHAR(64),
    payment_id          VARCHAR(64),
    merchant_id         VARCHAR(32),
    merchant_name       VARCHAR(256),
    region              VARCHAR(8),
    country             VARCHAR(4),
    card_brand          VARCHAR(16),
    issuer_bin          VARCHAR(8),
    payment_method      VARCHAR(16),
    amount              NUMBER(12,2),
    currency            VARCHAR(4),
    auth_status         VARCHAR(16),
    decline_code        VARCHAR(32),
    auth_latency_ms     INTEGER
)
    CLUSTER BY (event_ts, env, merchant_id, auth_status)
    TARGET_LAG = '60 seconds'
    WAREHOUSE = PAYMENTS_REFRESH_WH
AS
WITH deduped_events AS (
    SELECT *
    FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW
    WHERE event_ts >= DATEADD('MINUTE', -60, CURRENT_TIMESTAMP())
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY env, event_id 
        ORDER BY ingested_at DESC
    ) = 1
)
SELECT
    event_ts,
    env,
    event_id,
    payment_id,
    merchant_id,
    merchant_name,
    region,
    country,
    card_brand,
    issuer_bin,
    payment_method,
    amount,
    currency,
    auth_status,
    decline_code,
    auth_latency_ms
FROM deduped_events
ORDER BY event_ts DESC;
```

**Interactive Table Constraints:**

- **DML:** Interactive tables support only `INSERT OVERWRITE`. `UPDATE` and `DELETE` are not supported. The auto-refresh via TARGET_LAG handles data population; no manual DML is needed for this use case.
- **Not chainable:** Interactive tables cannot be sources for streams or serve as base tables for dynamic tables. The curated dynamic tables (Section 3.8) must read from the raw landing table, not from interactive tables.
- **Column definitions required:** Unlike dynamic tables which infer schema from the AS query, interactive tables require explicit column definitions in the DDL.

### 3.6 Interactive Warehouse

```sql
CREATE OR REPLACE INTERACTIVE WAREHOUSE PAYMENTS_INTERACTIVE_WH
    TABLES (
        PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS,
        PAYMENTS_DB.SERVE.IT_AUTH_EVENT_SEARCH
    )
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 86400
    AUTO_RESUME = TRUE;

-- Resume after creation (interactive warehouses are created suspended)
ALTER WAREHOUSE PAYMENTS_INTERACTIVE_WH RESUME;
```

**Operational Notes:**

- Minimum AUTO_SUSPEND is 86400 seconds (24 hours). Snowflake enforces this floor.
- Cache warm-up after resume takes minutes to ~1 hour depending on data volume. Plan to resume the warehouse well before a demo.
- Interactive warehouses can only query interactive tables. Use a standard warehouse for all other work.
- Cannot run CALL commands or use the `->>` pipe operator in interactive warehouses.
- Interactive warehouses do not currently support replication.
- This warehouse serves the shared database, enabling cross-environment dashboard queries by filtering on `env`.

### 3.7 Standard Warehouses

```sql
-- Refresh warehouse: powers interactive table and dynamic table refreshes
CREATE OR REPLACE WAREHOUSE PAYMENTS_REFRESH_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 120
    AUTO_RESUME = TRUE
    COMMENT = 'Refresh compute for interactive tables and dynamic tables';

-- Admin warehouse: schemachange migrations, dbt runs, ad-hoc queries
CREATE OR REPLACE WAREHOUSE PAYMENTS_ADMIN_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    COMMENT = 'Admin and CI/CD operations';
```

### 3.8 Curated Path — dbt-Managed Dynamic Tables

These are not on the live dashboard's hot path. They serve broader BI, ML, and data-quality use cases.

**Note:** Curated models read from the shared raw landing table and filter by `env` as needed. All curated tables live in `PAYMENTS_DB.CURATED`.

#### 3.8.1 Enriched Events

```sql
-- dbt model: curated/dt_auth_enriched.sql
-- materialized = 'dynamic_table', target_lag = '5 minutes'

CREATE OR REPLACE DYNAMIC TABLE PAYMENTS_DB.CURATED.DT_AUTH_ENRICHED
    TARGET_LAG = '5 minutes'
    WAREHOUSE = PAYMENTS_REFRESH_WH
    REFRESH_MODE = INCREMENTAL
AS
SELECT
    r.*,
    CASE
        WHEN r.auth_latency_ms < 100  THEN 'FAST'
        WHEN r.auth_latency_ms < 300  THEN 'NORMAL'
        WHEN r.auth_latency_ms < 1000 THEN 'SLOW'
        ELSE 'CRITICAL'
    END AS latency_tier,
    CASE
        WHEN r.auth_status = 'DECLINED' AND r.decline_code IN (
            'ISSUER_UNAVAILABLE', 'NETWORK_ERROR', 'TIMEOUT'
        ) THEN TRUE
        ELSE FALSE
    END AS is_system_decline,
    CASE
        WHEN r.amount > 5000 THEN 'HIGH_VALUE'
        WHEN r.amount > 1000 THEN 'MEDIUM_VALUE'
        ELSE 'STANDARD'
    END AS value_tier
FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW r
WHERE r.event_ts >= DATEADD('DAY', -7, CURRENT_TIMESTAMP());
```

#### 3.8.2 Hourly Rollup

```sql
-- dbt model: curated/dt_auth_hourly.sql
-- materialized = 'dynamic_table', target_lag = '30 minutes'

CREATE OR REPLACE DYNAMIC TABLE PAYMENTS_DB.CURATED.DT_AUTH_HOURLY
    TARGET_LAG = '30 minutes'
    WAREHOUSE = PAYMENTS_REFRESH_WH
AS
SELECT
    DATE_TRUNC('HOUR', event_ts)    AS event_hour,
    env,
    region,
    country,
    card_brand,
    merchant_id,
    merchant_name,
    COUNT(*)                        AS total_events,
    COUNT_IF(auth_status = 'APPROVED')  AS approvals,
    COUNT_IF(auth_status = 'DECLINED')  AS declines,
    ROUND(COUNT_IF(auth_status = 'APPROVED') / NULLIF(COUNT(*), 0), 4) AS approval_rate,
    SUM(auth_latency_ms)            AS latency_sum_ms,
    COUNT(auth_latency_ms)          AS latency_count,
    SUM(amount)                     AS total_amount
FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW
GROUP BY ALL;
```

**Note:** Latency uses `SUM/COUNT` (not `AVG`) so that hourly rows can be correctly reaggregated at higher levels (daily, weekly). Compute weighted average as `latency_sum_ms / NULLIF(latency_count, 0)`. The `approval_rate` column uses inline expressions (not column aliases) because Snowflake does not allow referencing aliases in the same SELECT level.

#### 3.8.3 Daily Rollup

```sql
-- dbt model: curated/dt_auth_daily.sql
-- materialized = 'dynamic_table', target_lag = '1 hour'

CREATE OR REPLACE DYNAMIC TABLE PAYMENTS_DB.CURATED.DT_AUTH_DAILY
    TARGET_LAG = '1 hour'
    WAREHOUSE = PAYMENTS_REFRESH_WH
AS
SELECT
    DATE_TRUNC('DAY', event_ts)     AS event_day,
    env,
    region,
    country,
    card_brand,
    merchant_id,
    merchant_name,
    COUNT(*)                        AS total_events,
    COUNT_IF(auth_status = 'APPROVED')  AS approvals,
    COUNT_IF(auth_status = 'DECLINED')  AS declines,
    ROUND(COUNT_IF(auth_status = 'APPROVED') / NULLIF(COUNT(*), 0), 4) AS approval_rate,
    SUM(auth_latency_ms)            AS latency_sum_ms,
    COUNT(auth_latency_ms)          AS latency_count,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY auth_latency_ms)
                                    AS p95_latency_ms,
    SUM(amount)                     AS total_amount,
    COUNT(DISTINCT merchant_id)     AS unique_merchants,
    COUNT(DISTINCT issuer_bin)      AS unique_issuers
FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW
GROUP BY ALL;
```

### 3.9 SPCS Application

#### 3.9.1 Compute Pool

```sql
CREATE COMPUTE POOL IF NOT EXISTS PAYMENTS_DASHBOARD_POOL
    MIN_NODES = 1
    MAX_NODES = 2
    INSTANCE_FAMILY = CPU_X64_S
    AUTO_SUSPEND_SECS = 3600
    AUTO_RESUME = TRUE
    COMMENT = 'Compute pool for Payment Command Center dashboard';
```

#### 3.9.2 Image Repository

```sql
-- Image repository in the shared database
CREATE IMAGE REPOSITORY IF NOT EXISTS PAYMENTS_DB.APP.DASHBOARD_REPO
    COMMENT = 'Container images for Payment Command Center';
```

**Image Build and Push:**

```bash
# Build
docker build -t payments-command-center:latest ./app

# Tag for Snowflake registry
docker tag payments-command-center:latest \
  <org>-<account>.registry.snowflakecomputing.com/payments_db/app/dashboard_repo/payments-command-center:latest

# Push
docker push \
  <org>-<account>.registry.snowflakecomputing.com/payments_db/app/dashboard_repo/payments-command-center:latest
```

#### 3.9.3 Service Specification

```yaml
# service_spec.yaml
spec:
  containers:
  - name: dashboard
    image: /payments_db/app/dashboard_repo/payments-command-center:latest
    env:
      SNOWFLAKE_WAREHOUSE: PAYMENTS_INTERACTIVE_WH
      SNOWFLAKE_DATABASE: PAYMENTS_DB
      SNOWFLAKE_SCHEMA_SERVE: SERVE
      SNOWFLAKE_SCHEMA_RAW: RAW
      APP_PORT: "8080"
    ports:
      - containerPort: 8080
    readinessProbe:
      port: 8080
      path: /health
    resources:
      requests:
        memory: 1Gi
        cpu: "1"
      limits:
        memory: 2Gi
        cpu: "2"
  endpoints:
  - name: dashboard-endpoint
    port: 8080
    public: true
  serviceRoles:
  - name: dashboard_viewer
    endpoints:
    - dashboard-endpoint
```

#### 3.9.4 Service Creation

```sql
-- Upload spec to stage
PUT file://service_spec.yaml @PAYMENTS_DB.APP.SPECS
    AUTO_COMPRESS = FALSE
    OVERWRITE = TRUE;

-- Create service
CREATE SERVICE IF NOT EXISTS PAYMENTS_DB.APP.COMMAND_CENTER
    IN COMPUTE POOL PAYMENTS_DASHBOARD_POOL
    FROM @PAYMENTS_DB.APP.SPECS
    SPECIFICATION_FILE = 'service_spec.yaml'
    MIN_INSTANCES = 1
    MAX_INSTANCES = 2
    COMMENT = 'Payment Authorization Command Center dashboard';

-- Grant access to operations role
GRANT SERVICE ROLE PAYMENTS_DB.APP.COMMAND_CENTER!dashboard_viewer
    TO ROLE PAYMENTS_OPS_ROLE;
```

#### 3.9.5 Application Stack

**Frontend:** React 18+, TypeScript

| Dependency | Purpose |
|---|---|
| `react` | UI framework |
| `recharts` or `@nivo/core` | Charts (time series, heatmaps) |
| `@tanstack/react-query` | Data fetching with auto-refresh |
| `tailwindcss` | Styling |
| `date-fns` | Date manipulation |

**Backend:** Python 3.11+, FastAPI

| Dependency | Purpose |
|---|---|
| `fastapi` | HTTP framework |
| `uvicorn` | ASGI server |
| `snowflake-connector-python` | Snowflake queries |
| `pydantic` | Request/response models |

**Connection Pattern:** The SPCS service runs under its owner role (`PAYMENTS_APP_ROLE`). The backend acquires a Snowflake session using the SPCS-internal login token endpoint (`/snowflake/session/token`), which provides OAuth tokens for the service's owner role without requiring external credentials. The backend maintains **two connection pools**: one using `PAYMENTS_INTERACTIVE_WH` for dashboard read queries against interactive tables, and one using `PAYMENTS_ADMIN_WH` for freshness queries against the raw standard table (since interactive warehouses cannot query standard tables). All queries filter by `env` based on the API request (e.g., `WHERE env IN ('dev', 'preprod', 'prod')`).

#### 3.9.6 Required Privileges

```sql
-- Account-level (verify current SPCS docs — BIND SERVICE ENDPOINT was used in earlier
-- previews; current model may rely solely on service roles defined in service_spec.yaml)
GRANT BIND SERVICE ENDPOINT ON ACCOUNT TO ROLE PAYMENTS_APP_ROLE;

-- Database/schema access (shared database)
GRANT USAGE ON DATABASE PAYMENTS_DB TO ROLE PAYMENTS_APP_ROLE;

GRANT USAGE ON SCHEMA PAYMENTS_DB.APP TO ROLE PAYMENTS_APP_ROLE;
GRANT USAGE ON SCHEMA PAYMENTS_DB.SERVE TO ROLE PAYMENTS_APP_ROLE;
GRANT USAGE ON SCHEMA PAYMENTS_DB.RAW TO ROLE PAYMENTS_APP_ROLE;

-- Compute
GRANT USAGE ON COMPUTE POOL PAYMENTS_DASHBOARD_POOL TO ROLE PAYMENTS_APP_ROLE;
GRANT USAGE ON WAREHOUSE PAYMENTS_INTERACTIVE_WH TO ROLE PAYMENTS_APP_ROLE;
GRANT USAGE ON WAREHOUSE PAYMENTS_ADMIN_WH TO ROLE PAYMENTS_APP_ROLE;

-- Tables (shared database)
GRANT SELECT ON ALL TABLES IN SCHEMA PAYMENTS_DB.SERVE TO ROLE PAYMENTS_APP_ROLE;
GRANT SELECT ON TABLE PAYMENTS_DB.RAW.AUTH_EVENTS_RAW TO ROLE PAYMENTS_APP_ROLE;

-- Service role (grants dashboard access to operations team)
GRANT SERVICE ROLE PAYMENTS_DB.APP.COMMAND_CENTER!dashboard_viewer
    TO ROLE PAYMENTS_OPS_ROLE;
```

---

## 4. Dashboard Screens

### 4.1 KPI Strip (Top Bar)

Four cards displayed horizontally:

| Card | Metric | Source | Computation |
|---|---|---|---|
| Auth Rate | Approval % over last 15 min | IT_AUTH_MINUTE_METRICS | `SUM(approval_count) / SUM(event_count)` |
| Decline Rate | Decline % over last 15 min | IT_AUTH_MINUTE_METRICS | `SUM(decline_count) / SUM(event_count)` |
| Avg Latency | Weighted mean auth latency (ms) | IT_AUTH_MINUTE_METRICS | `SUM(latency_sum_ms) / SUM(latency_count)` |
| Event Volume | Events/minute (current) | IT_AUTH_MINUTE_METRICS | `SUM(event_count)` for latest minute |

Each card shows the current value and a delta indicator comparing to the previous 15-minute window.

**Note:** Average latency is computed as a weighted average using sum and count columns to ensure statistical correctness across multiple minute buckets and filter dimensions.

### 4.2 Time Series Panel

- X-axis: minute buckets over the selected time range (default: last 60 minutes).
- Y-axis (left): event volume (bar chart).
- Y-axis (right): decline rate % (line overlay).
- Source: `IT_AUTH_MINUTE_METRICS`, aggregated across selected filters.
- Auto-refresh: every 15 seconds (polls backend).

### 4.3 Breakdown Heatmap / Table

A sortable table (or heatmap) showing the top affected dimensions:

| Dimension | Events | Decline Rate | Avg Latency | Delta vs Prev Period |
|---|---|---|---|---|
| Merchant | Top 20 | Per merchant | Per merchant | Color-coded |
| Region | All | Per region | Per region | Color-coded |
| Issuer BIN | Top 20 | Per BIN | Per BIN | Color-coded |
| Card Brand | All | Per brand | Per brand | Color-coded |

Toggle between dimensions via tabs. Source: `IT_AUTH_MINUTE_METRICS`.

### 4.4 Recent Failures Panel

A scrollable table of the most recent declined/errored transactions:

| Column | Source |
|---|---|
| Timestamp | `event_ts` |
| Payment ID | `payment_id` (synthetic) |
| Merchant | `merchant_name` (fictional) |
| Amount | `amount` + `currency` |
| Status | `auth_status` |
| Decline Code | `decline_code` |
| Latency | `auth_latency_ms` |

Source: `IT_AUTH_EVENT_SEARCH` filtered to `auth_status IN ('DECLINED', 'ERROR', 'TIMEOUT')`, ordered by `event_ts DESC`, limited to 100 rows.

Click a row to expand full event details. **Note:** The drill-down detail view excludes `headers` and `payload` columns per the display policy (Section 3.5.2). All displayed identifiers are synthetic.

### 4.5 Compare Mode

Side-by-side comparison:

- **Current window:** last 15 minutes.
- **Previous window:** 15 minutes before that.

Displays delta for: approval rate, decline rate, avg latency, p95 latency, event volume, top decline codes.

Source: Two queries against `IT_AUTH_MINUTE_METRICS` with different time predicates.

### 4.6 Latency Panel

- **Histogram:** Latency distribution in buckets (0-50ms, 50-100ms, 100-200ms, 200-500ms, 500ms-1s, >1s).
  - **Source:** `IT_AUTH_MINUTE_METRICS` histogram bucket columns (`latency_0_50ms`, `latency_50_100ms`, etc.)
  - **Computation:** Sum bucket counts across the selected time range and filters
- **Summary stats:** 
  - **Average latency:** `SUM(latency_sum_ms) / SUM(latency_count)` from `IT_AUTH_MINUTE_METRICS`
  - **Percentiles (p50, p95, p99):** Computed from `IT_AUTH_EVENT_SEARCH` using `PERCENTILE_CONT` over raw event-level `auth_latency_ms` values for the selected time range
- **Time series:** p95 and p99 latency over time
  - **Source:** `IT_AUTH_EVENT_SEARCH` with time-bucketed percentile aggregation

**Design Note:** Percentile calculations require raw event-level data and cannot be accurately recomputed from pre-aggregated minute buckets. The event search table provides this granularity at the cost of querying more rows. For large time ranges (>1 hour), consider adding a sampling strategy or limiting percentile queries to smaller windows.

### 4.7 Freshness Widget

A small indicator showing:

- **Raw ingest heartbeat:** `MAX(ingested_at)` from `PAYMENTS_DB.RAW.AUTH_EVENTS_RAW` filtered by selected `env` values — shows seconds-level arrival.
- **Serving layer freshness:** `SYSTEM$DYNAMIC_TABLE_REFRESH_HISTORY` or `MAX(event_minute)` from `IT_AUTH_MINUTE_METRICS` filtered by selected `env`.
- **Display format:** "Raw: 3s ago | Serving: 47s ago"

This is important for the demo narrative: the audience sees that raw data arrives in seconds even though the interactive serving layer refreshes on a 60-second cadence.

**Note:** The freshness query against `PAYMENTS_DB.RAW.AUTH_EVENTS_RAW` must use a standard warehouse (not the interactive warehouse), since the raw table is a standard table. The backend uses a separate connection pool with `PAYMENTS_ADMIN_WH` for this query (see Section 3.9.5 Connection Pattern).

### 4.8 Filter Controls

Persistent filter bar (Grafana-style) at the top of the dashboard:

| Filter | Type | Values |
|---|---|---|
| Time Range | Dropdown + custom | Last 15m, 30m, 1h, 2h, custom |
| Environment | Multi-select | dev, preprod, prod |
| Merchant | Searchable dropdown | Top merchants + search |
| Region | Multi-select | NA, EU, APAC, LATAM |
| Country | Searchable dropdown | ISO codes |
| Card Brand | Multi-select | VISA, MASTERCARD, AMEX, DISCOVER |
| Issuer BIN | Text input | Free-text partial match |
| Payment Method | Multi-select | CREDIT, DEBIT, PREPAID |
| Auth Status | Multi-select | APPROVED, DECLINED, ERROR, TIMEOUT |
| Decline Code | Searchable dropdown | Known codes |
| Payment/Order ID | Text input | Exact match search |

---

## 5. API Contract

All endpoints are served by the Python backend at the SPCS public endpoint URL.

### 5.1 GET `/api/v1/filters`

Returns available filter values for populating dropdowns.

**Response:**

```json
{
  "merchants": [{"id": "merch-0042", "name": "Acme Electronics"}, ...],
  "regions": ["NA", "EU", "APAC", "LATAM"],
  "countries": ["US", "CA", "GB", ...],
  "card_brands": ["VISA", "MASTERCARD", "AMEX", "DISCOVER"],
  "payment_methods": ["CREDIT", "DEBIT", "PREPAID"],
  "auth_statuses": ["APPROVED", "DECLINED", "ERROR", "TIMEOUT"],
  "decline_codes": ["DO_NOT_HONOR", "INSUFFICIENT_FUNDS", "ISSUER_UNAVAILABLE", ...]
}
```

**Source:** `SELECT DISTINCT` queries against `IT_AUTH_MINUTE_METRICS`.

### 5.2 GET `/api/v1/summary`

Returns KPI strip values.

**Query Parameters:** `time_range`, `env`, `merchant_id`, `region`, `card_brand` (all optional filters).

**Response:**

```json
{
  "current": {
    "approval_rate": 0.9523,
    "decline_rate": 0.0412,
    "avg_latency_ms": 94.3,
    "events_per_minute": 1247
  },
  "previous": {
    "approval_rate": 0.9601,
    "decline_rate": 0.0344,
    "avg_latency_ms": 87.1,
    "events_per_minute": 1189
  },
  "freshness": {
    "raw_ingested_at": "2026-03-30T16:29:57Z",
    "serving_last_minute": "2026-03-30T16:29:00Z"
  }
}
```

**Implementation Note:** Average latency is computed as `SUM(latency_sum_ms) / SUM(latency_count)` to ensure statistical correctness across multiple minute buckets.

### 5.3 GET `/api/v1/timeseries`

Returns minute-by-minute data for the time series panel.

**Query Parameters:** `time_range` (required), plus optional filters.

**Response:**

```json
{
  "buckets": [
    {
      "minute": "2026-03-30T16:00:00Z",
      "event_count": 1234,
      "decline_rate": 0.041,
      "avg_latency_ms": 92.1
    },
    ...
  ]
}
```

**Implementation Note:** For each minute bucket, `avg_latency_ms` is computed as `latency_sum_ms / latency_count` for that specific minute. Percentile values are not included in the timeseries response; use the latency panel endpoint for percentile calculations.

### 5.4 GET `/api/v1/breakdown`

Returns top-N breakdown by a specified dimension.

**Query Parameters:** `dimension` (required: `merchant`, `region`, `country`, `card_brand`, `issuer_bin`), `time_range`, `limit` (default 20), plus optional filters.

**Response:**

```json
{
  "dimension": "merchant",
  "rows": [
    {
      "key": "merch-0042",
      "label": "Acme Electronics",
      "event_count": 5432,
      "decline_rate": 0.082,
      "avg_latency_ms": 105.2,
      "delta_decline_rate": 0.031
    },
    ...
  ]
}
```

### 5.5 GET `/api/v1/events`

Returns recent individual events for the failures panel and drill-down.

**Query Parameters:** `time_range`, `auth_status` (default: `DECLINED,ERROR,TIMEOUT`), `payment_id` (exact match), `limit` (default 100), plus optional filters.

**Response:**

```json
{
  "events": [
    {
      "event_ts": "2026-03-30T16:29:45.123Z",
      "event_id": "evt-...",
      "payment_id": "pay-...",
      "merchant_name": "Acme Electronics",
      "amount": 149.99,
      "currency": "USD",
      "auth_status": "DECLINED",
      "decline_code": "DO_NOT_HONOR",
      "auth_latency_ms": 312,
      "region": "NA",
      "card_brand": "VISA"
    },
    ...
  ],
  "total_count": 847
}
```

**Source:** `IT_AUTH_EVENT_SEARCH`.

### 5.6 GET `/api/v1/latency`

Returns latency histogram and percentile statistics.

**Query Parameters:** `time_range` (required), plus optional filters, `max_limit` (default 10000, max events to analyze for percentiles).

**Response:**

```json
{
  "histogram": {
    "0_50ms": 8234,
    "50_100ms": 1456,
    "100_200ms": 234,
    "200_500ms": 89,
    "500_1000ms": 12,
    "1000ms_plus": 3
  },
  "statistics": {
    "avg_latency_ms": 92.4,
    "p50_latency_ms": 87.0,
    "p95_latency_ms": 198.5,
    "p99_latency_ms": 312.1,
    "min_latency_ms": 23,
    "max_latency_ms": 1842,
    "event_count": 10028
  }
}
```

**Source:** 
- Histogram: `IT_AUTH_MINUTE_METRICS` histogram bucket columns
- Percentiles: `IT_AUTH_EVENT_SEARCH` with `PERCENTILE_CONT` over `auth_latency_ms`

**Implementation Note:** Percentile calculations query event-level data. For time ranges >1 hour, consider limiting the number of events analyzed or implementing sampling to maintain query performance.

### 5.7 Query Safety

All API query templates are:

- **Parameterized** — no string interpolation of user input into SQL.
- **Bounded** — every query has a `LIMIT` clause and a time predicate. No arbitrary ad hoc SQL from the browser.
- **Selective** — queries use `WHERE` clauses that align with the CLUSTER BY keys of the interactive tables.
- **Warehouse-routed** — dashboard reads use the interactive warehouse; freshness checks use a standard warehouse.

---

## 6. Environment Model

### 6.1 Shared Raw Landing with Logical Environment Separation

All environments (`dev`, `preprod`, `prod`) run within **one Snowflake account** and share **one raw landing table**. Environment separation is **logical**, not physical, at the raw layer.

| Environment | Kafka Topic | Raw Table | Purpose |
|---|---|---|---|
| Development | `payments.auth` | `PAYMENTS_DB.RAW.AUTH_EVENTS_RAW` | Feature development, testing |
| Pre-production | `payments.auth` | `PAYMENTS_DB.RAW.AUTH_EVENTS_RAW` | Integration testing, staging |
| Production | `payments.auth` | `PAYMENTS_DB.RAW.AUTH_EVENTS_RAW` | Live operations |

**Key Design Choices:**

- **One Kafka topic** (`payments.auth`) carries events from all environments.
- **One raw landing table** (`PAYMENTS_DB.RAW.AUTH_EVENTS_RAW`) stores events from all environments.
- **`env` column** (`dev`, `preprod`, `prod`) in each event provides logical environment isolation.
- **Dashboard and serving layers filter by `env`** to provide environment-specific or cross-environment views.

**Rationale:**

- Reduces operational overhead (one ingest pipeline vs. three).
- Simplifies Kafka Connect configuration (one connector, one target).
- Enables unified cross-environment dashboards without database switching or union queries.
- Maintains demo simplicity while illustrating production patterns through governance, monitoring, and explicit blast-radius documentation.

**Production Note:** In a production system, environments would use separate Kafka topics and potentially separate raw tables for blast-radius isolation, independent offset management, and per-environment access control. The shared-topic/shared-table model is a deliberate demo simplification.

**Trade-offs:**

- **Physical isolation:** Environments do not have separate raw tables or databases. Mistakes in tagging or querying could mix environments at raw. Mitigations: strict event generation validation, query-time `WHERE env = ?` filters, governance policies.
- **Blast radius:** One ingest outage affects all environments. Fallback batch ingest path is explicitly documented for demo continuity.
- **Noisy neighbor:** High volume in one environment (e.g., prod spike) could impact ingest for others. Kafka partition allocation and Snowflake streaming credits are shared across environments.

### 6.2 Naming Conventions

| Object | Pattern | Example |
|---|---|---|
| Database | `PAYMENTS_DB` | Primary database for all environments |
| Schema (raw) | `RAW` | `PAYMENTS_DB.RAW` (shared landing) |
| Schema (serve) | `SERVE` | `PAYMENTS_DB.SERVE` (interactive tables) |
| Schema (curated) | `CURATED` | `PAYMENTS_DB.CURATED` (dbt models) |
| Schema (app) | `APP` | `PAYMENTS_DB.APP` (SPCS deployment) |
| Kafka topic | `payments.auth` | Single shared topic |
| Kafka Connect connector | `auth-events-sink-payments` | Single connector |
| Kafka Connect consumer group | `snowflake-hp-sink-payments` | Single consumer group |

**Shared Objects:** The following objects are shared across all environments:

- Database (`PAYMENTS_DB`)
- Raw landing table (`PAYMENTS_DB.RAW.AUTH_EVENTS_RAW`)
- Serving tables (filter by `env` at query time)
- Interactive warehouse
- Standard warehouses (refresh and admin)
- Compute pool (SPCS)
- SPCS service

### 6.3 Role Hierarchy

```text
ACCOUNTADMIN
  └── SYSADMIN
        └── PAYMENTS_ADMIN_ROLE     (Terraform, schemachange, dbt)
              ├── PAYMENTS_APP_ROLE   (SPCS service owner, SELECT on shared database)
              ├── PAYMENTS_INGEST_ROLE (Snowpipe Streaming, WRITE to shared raw table)
              └── PAYMENTS_OPS_ROLE   (Dashboard viewers, granted service role)
```

---

## 7. Change Management Toolchain

**Why three tools?** Terraform, schemachange, and dbt each own a distinct layer of the Snowflake estate. This separation is standard practice in Snowflake projects:

| Layer | Tool | What It Manages | Why Not the Others? |
|---|---|---|---|
| Infrastructure | Terraform | Databases, schemas, warehouses, compute pools, roles, grants, image repos, stages | dbt and schemachange cannot manage account-level objects |
| DDL Migrations | schemachange | Raw landing tables, interactive tables, masking/row-access policies, SPCS service DDL, object-level grants | dbt cannot manage tables without a defining SELECT (Snowpipe targets), interactive tables (no native materialization), or SPCS DDL |
| Transformations | dbt | Curated dynamic tables, data quality tests, documentation, source definitions | Terraform and schemachange don't handle transformation logic or testing |

dbt-snowflake supports dynamic table materialization but **cannot** manage: raw landing tables (Snowpipe ingest targets have no defining query), interactive tables (no native materialization support), SPCS service DDL, compute pools, or policy objects as first-class resources.

### 7.1 Terraform — Infrastructure Scaffolding

**Scope:** Account-level and long-lived Snowflake objects.

| Object Type | Managed By Terraform |
|---|---|
| Databases | Yes |
| Schemas | Yes |
| Warehouses (standard + interactive) | Yes |
| Compute pools | Yes |
| Roles | Yes |
| Role grants | Yes |
| Image repositories | Yes |
| Stages | Yes |
| Resource monitors | Yes |

**Provider:** `snowflake-labs/snowflake` (GA).

**State:** Remote backend (e.g., S3 + DynamoDB for locking). Single state file for the single-account deployment.

### 7.2 schemachange — DDL Migrations

**Scope:** SQL DDL that is awkward to model in dbt or Terraform.

| Object Type | Managed By schemachange |
|---|---|
| Landing tables (raw) | Yes |
| Interactive tables | Yes |
| Masking/row-access policies | Yes |
| Grants on specific objects | Yes |
| Service-related DDL | Yes |

**Migration Naming:** `V1.0.0__create_raw_schema.sql`, `V1.1.0__create_landing_table.sql`, etc.

**Execution:** `schemachange deploy` in CI, per-database config.

### 7.3 dbt — Transformations and Tests

**Scope:** Curated dynamic tables, data quality tests, documentation.

| Object Type | Managed By dbt |
|---|---|
| Dynamic tables (curated path) | Yes (`materialized='dynamic_table'`) |
| Data quality tests | Yes (generic + singular) |
| Documentation | Yes |
| Source definitions | Yes |

**Adapter:** `dbt-snowflake` with dynamic table support.

**Project Layout:** See Section 8 (Repository Structure).

### 7.4 Snowflake CLI — App Deployment and CI/CD Glue

**Scope:** SPCS deployment, dbt project operations, Git integration.

| Operation | CLI Command |
|---|---|
| SPCS deploy | `snow spcs service deploy` |
| dbt deploy | `snow dbt deploy` |
| dbt run | `snow dbt run` |
| Config per env | `--config-file env/{env}/config.toml` |

### 7.5 DCM Projects — Future Pilot

**Status:** Preview. Not recommended as the primary promotion path today.

**Pilot Plan:** After the initial build stabilizes, evaluate DCM Projects for the interactive table and landing-table definitions. DCM Projects support declarative definitions, templating, and multi-account deployment, which could simplify the schemachange layer.

### 7.6 GitHub Actions — CI/CD Pipeline

**Workflow Stages:**

```text
PR opened/updated:
  1. Lint (SQL + Python + TypeScript)
  2. Validate Kafka Connect config
  3. dbt compile + test (against shared database)
  4. schemachange dry-run
  5. Terraform plan
  6. Docker build (no push)

Merge to main:
  1. Terraform apply (provisions shared account-level objects and database)
  2. schemachange deploy (shared database)
  3. dbt run + test (shared database)
  4. Build and publish app image
  5. Deploy/update SPCS service
  6. Deploy/update shared Kafka Connect config
```

**Note:** All environments share one account and one database. Terraform manages the account-level objects (warehouses, compute pool, roles, database) once. Schema and table deployments are to the shared database using schemachange and dbt. The Kafka Connect config is deployed as a single shared connector.

---

## 8. Repository Structure

```text
payment-command-center/
├── .github/
│   └── workflows/
│       ├── ci.yml                    # PR checks
│       ├── deploy-dev.yml            # Deploy to dev
│       ├── promote-preprod.yml       # Promote to preprod
│       └── promote-prod.yml          # Promote to prod (manual gate)
├── terraform/
│   ├── main.tf                       # Provider config
│   ├── variables.tf
│   ├── outputs.tf
│   ├── database.tf                   # PAYMENTS_DB (shared database)
│   ├── schemas.tf                    # RAW, SERVE, CURATED, APP (in shared database)
│   ├── warehouses.tf                 # Interactive WH, Refresh WH, Admin WH
│   ├── compute_pools.tf              # PAYMENTS_DASHBOARD_POOL
│   ├── roles.tf                      # Role hierarchy
│   ├── grants.tf                     # All grants
│   └── stages.tf                     # Spec stage, image repo
├── schemachange/
│   ├── migrations/
│   │   ├── V1.0.0__create_database.sql
│   │   ├── V1.1.0__create_raw_landing_table.sql
│   │   ├── V1.2.0__create_interactive_tables.sql
│   │   └── V1.3.0__create_interactive_warehouse_tables_assoc.sql
│   └── schemachange-config.yml
├── dbt/
│   ├── dbt_project.yml
│   ├── profiles.yml
│   ├── packages.yml
│   ├── models/
│   │   ├── staging/
│   │   │   └── stg_auth_events.yml   # Source definition
│   │   └── curated/
│   │       ├── dt_auth_enriched.sql
│   │       ├── dt_auth_hourly.sql
│   │       ├── dt_auth_daily.sql
│   │       └── curated.yml           # Tests + docs
│   └── tests/
│       └── assert_no_null_event_ids.sql
├── generator/
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── main.py                       # FastAPI control server
│   ├── producer.py                   # Kafka producer (tags events with env)
│   ├── scenarios.py                  # Scenario profiles
│   ├── catalog.py                    # Fixed merchant/BIN/region catalog
│   └── config.py                     # Environment config
├── kafka-connect/
│   ├── README.md                     # Connector deployment instructions
│   └── shared.json                   # Shared connector config (payments.auth -> PAYMENTS_DB.RAW)
├── fallback_ingest/
│   ├── pyproject.toml                # Python relay dependencies
│   ├── relay.py                      # Kafka consumer -> Snowflake batch relay
│   ├── sf_client.py                  # Snowflake connection and batch write helpers
│   └── config.py                     # Fallback ingest config
├── app/
│   ├── Dockerfile                    # Multi-stage: build React, serve with Python
│   ├── backend/
│   │   ├── requirements.txt
│   │   ├── main.py                   # FastAPI app
│   │   ├── routes/
│   │   │   ├── summary.py
│   │   │   ├── timeseries.py
│   │   │   ├── breakdown.py
│   │   │   ├── events.py
│   │   │   └── filters.py
│   │   ├── queries/                  # SQL templates (parameterized, filter by env)
│   │   │   ├── summary.sql
│   │   │   ├── timeseries.sql
│   │   │   ├── breakdown.sql
│   │   │   ├── events.sql
│   │   │   └── filters.sql
│   │   └── snowflake_client.py       # Connection management
│   └── frontend/
│       ├── package.json
│       ├── tsconfig.json
│       ├── tailwind.config.js
│       ├── src/
│       │   ├── App.tsx
│       │   ├── components/
│       │   │   ├── KPIStrip.tsx
│       │   │   ├── TimeSeriesChart.tsx
│       │   │   ├── BreakdownTable.tsx
│       │   │   ├── RecentFailures.tsx
│       │   │   ├── CompareMode.tsx
│       │   │   ├── LatencyPanel.tsx
│       │   │   ├── FreshnessWidget.tsx
│       │   │   └── FilterBar.tsx
│       │   ├── hooks/
│       │   │   └── useApiQuery.ts
│       │   └── types/
│       │       └── api.ts
│       └── public/
│           └── index.html
├── spcs/
│   ├── service_spec.yaml             # SPCS service specification
│   └── snowflake.yml                 # Snowflake CLI project config
└── snowflake.yml                     # Root Snowflake CLI config
```

---

## 9. Constraints and Risks

### 9.1 Hard Constraints

| Constraint | Impact | Mitigation |
|---|---|---|
| Interactive tables: minimum TARGET_LAG = 60 seconds | Dashboard serving layer cannot refresh faster than once per minute | Freshness widget shows raw ingest heartbeat (seconds-level) alongside serving freshness |
| Interactive warehouses: minimum AUTO_SUSPEND = 86400 (24h) | Continuous credit consumption while the warehouse is active | Acceptable for demo; in production, interactive warehouses are intended to run 24x7 |
| Interactive warehouses: can only query interactive tables | Cannot query RAW table from interactive warehouse | Backend uses separate session with standard warehouse for freshness/raw queries |
| Interactive warehouses: no CALL, no `->>` operator | Cannot use stored procedures from interactive warehouse | All query logic is plain SQL in the backend |
| Interactive tables: INSERT OVERWRITE only (no UPDATE/DELETE) | Cannot perform row-level DML on serving tables | Not needed — TARGET_LAG auto-refresh handles all data population |
| Interactive tables: cannot source streams or dynamic tables | Cannot chain interactive tables into dynamic table pipelines | Curated dynamic tables (Section 3.8) read directly from the raw landing table |
| SPCS public endpoints: users must be Snowflake users in the same account | Dashboard access limited to Snowflake account members | Fits the internal payment-ops use case; external access would require a proxy. **V1: Demo viewers are passive and do not need direct access.** |
| SPCS public endpoints: require BIND SERVICE ENDPOINT privilege (verify status) | May be required for public endpoints; verify against current SPCS docs as this may be superseded by service roles | Included in Terraform grants with verification note |
| Shared Kafka topic and shared raw landing table | All environments share ingest pipeline; mis-tagged `env` field or one environment's volume spike affects all | Validate `env` field at event generation; monitor per-env ingest lag; document fallback path explicitly |

### 9.2 V1 Exclusions and Future Enhancements

**Not Included in V1:**

| Feature | V1 Status | Future Consideration |
|---|---|---|
| Late-arriving event handling | Not included. Assumes timely event arrival. | Add watermarking or late-arrival buffering in V2 |
| External viewer authentication | Not included. Viewers are passive demo observers. | Implement OAuth or external SSO proxy for external dashboards |
| Multi-account federation | Not included. All environments in one account. | Consider account-level isolation for production |
| Real cardholder data | Prohibited. Synthetic data only. | Add masking policies and PCI compliance controls |
| Cross-region replication | Not included. | Add for disaster recovery scenarios |

### 9.3 Preview / Limited Availability Features

| Feature | Status (as of March 2026) | Risk | Mitigation |
|---|---|---|---|
| HP Kafka Connector (v4.x) | Public Preview (Dec 2025). Selected accounts only. | Primary ingest path may not be available or stable on the demo account | Maintain Python batch fallback path and validate connector access early |
| DCM Projects | Preview | Not production-ready for promotion backbone | Use Terraform + schemachange as primary; pilot DCM Projects separately |
| Interactive tables + warehouses | Selected AWS regions | May not be available in all target regions | Confirm region availability before provisioning |

### 9.4 Operational Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Interactive warehouse cache cold at demo time | Medium | First queries slow (minutes to ~1 hour warm-up) | Resume warehouse and run warm-up queries at least 1 hour before demo |
| HP Kafka connector preview instability or account access gap | Medium | Primary ingest path unavailable for demo | Keep fallback Python batch relay production-ready enough for demo cutover; accept ~1-3 min latency |
| Shared Kafka topic: one connector outage affects all environments | Medium | All environments stop ingesting if connector fails | Monitor connector health; maintain batch fallback path |
| Shared raw table: mis-tagged env field causes environment data mixing | Low | Query results show wrong environment's data | Validate `env` field at event generation; add dashboard query-time validation |
| Noisy neighbor: one environment's volume spike impacts others | Medium | High volume in one env slows ingest for all | Size Kafka partitions and Snowflake streaming credits for combined peak; monitor per-env lag |
| Interactive table refresh falls behind during traffic spikes | Medium | Serving data becomes stale beyond 60 seconds | Monitor `DYNAMIC_TABLE_REFRESH_HISTORY`; alert if lag exceeds 2x target |
| Event generator produces unrealistic data distribution | Medium | Demo feels synthetic | Use deterministic seeds and curated merchant/BIN/region catalogs |

---

## 10. References

| # | Title | URL |
|---|---|---|
| 1 | Snowpipe Streaming Classic Overview | https://docs.snowflake.com/en/user-guide/snowpipe-streaming/snowpipe-streaming-classic-overview |
| 2 | CREATE DYNAMIC TABLE | https://docs.snowflake.com/en/sql-reference/sql/create-dynamic-table |
| 3 | Snowpipe Streaming Overview | https://docs.snowflake.com/en/user-guide/snowpipe-streaming/data-load-snowpipe-streaming-overview |
| 4 | HP Kafka Connector | https://docs.snowflake.com/en/connectors/kafkahp/about |
| 5 | Interactive Tables and Warehouses | https://docs.snowflake.com/en/user-guide/interactive |
| 6 | Dynamic Tables Overview | https://docs.snowflake.com/en/user-guide/dynamic-tables-about |
| 7 | SPCS Overview | https://docs.snowflake.com/en/developer-guide/snowpark-container-services/overview |
| 8 | SPCS Network Communications | https://docs.snowflake.com/en/developer-guide/snowpark-container-services/service-network-communications |
| 9 | DCM Projects Enterprise | https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-enterprise |
| 10 | Terraform Provider for Snowflake | https://docs.snowflake.com/en/user-guide/terraform |
| 11 | schemachange (Snowflake Labs) | https://github.com/Snowflake-Labs/schemachange |
| 12 | dbt Snowflake Configs | https://docs.getdbt.com/reference/resource-configs/snowflake-configs |
| 13 | Snowflake CLI CI/CD Integration | https://docs.snowflake.com/en/developer-guide/snowflake-cli/cicd/integrate-ci-cd |
| 14 | DCM Projects Usage | https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-use |
| 15 | Snowpipe Streaming HP Best Practices | https://docs.snowflake.com/en/user-guide/snowpipe-streaming/snowpipe-streaming-high-performance-best-practices |
| 16 | SPCS Service Specification Reference | https://docs.snowflake.com/en/developer-guide/snowpark-container-services/specification-reference |
| 17 | Snowflake HP Kafka Connector Setup | https://docs.snowflake.com/en/connectors/kafkahp/setup-kafka |
| 18 | Snowflake Connector for Python | https://docs.snowflake.com/en/developer-guide/python-connector/python-connector-pandas |
