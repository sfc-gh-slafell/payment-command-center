# Data Flow: Event Generation to Dashboard

This document traces every hop data takes from origination to dashboard pixel in the Payment Authorization Command Center. Each section covers the exact transformation, schema, configuration, and latency at that stage.

> **All data is synthetic.** No real cardholder data or PCI-sensitive information is used anywhere in this pipeline.

---

## End-to-End Overview

```
                           ORIGINATION
                               │
          generator/producer.py │  <1ms
          (confluent_kafka)     │
                               ▼
                   ┌───────────────────────┐
                   │  Kafka Topic           │
                   │  payments.auth         │
                   │  24 partitions, zstd   │
                   │  72h retention         │
                   └─────────┬─────────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
      PRIMARY PATH                  FALLBACK PATH
     HP Connector v4.x            Python Batch Relay
      5-10s latency                1-3 min latency
              │                             │
              └──────────────┬──────────────┘
                             │
                             ▼
               ┌──────────────────────────┐
               │  PAYMENTS_DB.RAW         │
               │  AUTH_EVENTS_RAW         │
               │  (22 columns + metadata) │
               │  14-day retention        │
               └─────────┬────────────────┘
                         │
          ┌──────────────┴──────────────────┐
          │                                 │
    HOT PATH (SERVE)              ANALYTICAL PATH (CURATED)
    Interactive Tables             dbt Dynamic Tables
    60s TARGET_LAG                 5min / 30min / 1hr lag
          │                                 │
          ▼                                 ▼
 ┌─────────────────────┐      ┌──────────────────────────┐
 │ IT_AUTH_MINUTE_      │      │ dt_auth_enriched (5m)    │
 │   METRICS (22 cols)  │      │ dt_auth_hourly   (30m)   │
 │ IT_AUTH_EVENT_       │      │ dt_auth_daily    (1h)    │
 │   SEARCH  (16 cols)  │      │                          │
 └────────┬────────────┘      └──────────────────────────┘
          │                     (BI / ML consumption)
          │
          ▼
 ┌─────────────────────────┐
 │ FastAPI Backend          │
 │ Dual warehouse routing   │
 │  • Interactive WH → SERVE│
 │  • Admin WH → RAW       │
 │ 6 API endpoints          │
 │ ~100-200ms query latency │
 └────────┬────────────────┘
          │
          ▼
 ┌─────────────────────────┐
 │ React Dashboard          │
 │ 8 UI components          │
 │ Polling refresh          │
 │ Freshness indicator      │
 └─────────────────────────┘

 TOTAL END-TO-END: ~65-75 seconds
```

---

## Hop 1: Event Generation → Kafka

### Source Files
- `generator/producer.py` — Kafka producer + event schema
- `generator/config.py` — Environment configuration
- `generator/scenarios.py` — Scenario profiles for demos
- `generator/catalog.py` — Merchant, BIN, region reference data
- `generator/main.py` — FastAPI control API

### Event Schema (16 fields)

The generator produces JSON events with these fields:

| Field | Type | Example | Description |
|-------|------|---------|-------------|
| `env` | string | `"dev"` | Environment: dev, preprod, prod |
| `event_ts` | ISO 8601 | `"2026-03-31T14:30:45+00:00"` | UTC event timestamp |
| `event_id` | UUID | `"a1b2c3d4-..."` | Unique identifier (dedup key within env) |
| `payment_id` | string | `"PAY-A1B2C3D4E5F6"` | Tokenized payment ID (synthetic) |
| `merchant_id` | string | `"M0003"` | Merchant identifier |
| `merchant_name` | string | `"TechBazaar"` | Merchant display name |
| `region` | string | `"NA"` | NA, EU, APAC, LATAM |
| `country` | string | `"US"` | ISO 3166-1 alpha-2 |
| `card_brand` | string | `"VISA"` | VISA, MASTERCARD, AMEX, DISCOVER |
| `issuer_bin` | string | `"411111"` | First 6-8 digits of card (synthetic) |
| `payment_method` | string | `"CREDIT"` | CREDIT, DEBIT, PREPAID |
| `amount` | float | `99.99` | 1.00 - 5,000.00 |
| `currency` | string | `"USD"` | Always USD in this demo |
| `auth_status` | string | `"APPROVED"` | APPROVED, DECLINED, ERROR, TIMEOUT |
| `decline_code` | string/null | `"DO_NOT_HONOR"` | Null if approved |
| `auth_latency_ms` | float | `75.2` | Round-trip latency in ms |

### Baseline Distribution
- **Approval rate:** ~95%
- **Latency range:** 50-150ms (uniform)
- **Non-approved outcomes:** Equal chance of DECLINED, ERROR, TIMEOUT
- **Amount range:** $1.00 - $5,000.00

### Kafka Producer Configuration

From `generator/producer.py:14-26`:

```python
Producer({
    "bootstrap.servers": BOOTSTRAP_SERVERS,  # env: KAFKA_BOOTSTRAP_SERVERS
    "compression.type": "zstd",
    "acks": "all",
    "linger.ms": 5,
    "batch.size": 16384,
    "message.max.bytes": 10485760,
})
```

- **Partition key:** `merchant_id` — ensures ordering per merchant
- **Serialization:** `json.dumps(event).encode("utf-8")`

### Kafka Topic Configuration

| Property | Value | Rationale |
|----------|-------|-----------|
| Topic name | `payments.auth` | Single topic for all environments |
| Partitions | 24 | Supports 2,000 events/sec with headroom |
| Replication factor | 3 (prod) / 1 (local) | Standard HA |
| Retention | 72 hours (259,200,000ms) | Replay window for connector recovery |
| Cleanup policy | `delete` | Time-based retention only |
| Compression | `zstd` | End-to-end compression |

### Throughput
- **Baseline:** 500 events/sec (configurable via `GENERATOR_RATE` or POST `/rate`)
- **Peak:** 2,000 events/sec

### Scenario Profiles

Scenarios modify events post-generation via `modify_event()` in `generator/scenarios.py`:

| Scenario | Target | Effect | Demo Signal |
|----------|--------|--------|-------------|
| `baseline` | All | No modification | Healthy state |
| `issuer_outage` | BIN prefix `4111` | 90% decline, code `ISSUER_UNAVAILABLE` | BIN-level failure spike |
| `merchant_decline_spike` | `M0003` (TechBazaar) | 60% decline, code `DO_NOT_HONOR` | Merchant anomaly |
| `latency_spike` | Region `EU` | Latency 800-2000ms, approval unaffected | Regional latency degradation |

### Latency at This Hop
**< 1ms** — in-process Kafka produce call.

---

## Hop 2: Kafka → Snowflake RAW (Primary Path — HP Connector)

### Source Files
- `kafka-connect/shared.json` — Connector configuration
- `kafka-connect/Dockerfile` — Kafka Connect runtime with HP connector JARs
- `terraform/pipes.tf` — Snowpipe Streaming pipe definition

### HP Connector Configuration

From `kafka-connect/shared.json`:

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
    "errors.log.enable": "true",
    "errors.log.include.messages": "true"
  }
}
```

### User-Defined Pipe (Snowpipe Streaming)

The HP connector operates in **user-defined pipe mode** — it matches the pipe name to the destination table (`AUTH_EVENTS_RAW`). The pipe's `COPY INTO` statement controls column mapping and Kafka metadata extraction.

From `terraform/pipes.tf`:

```sql
CREATE PIPE IF NOT EXISTS PAYMENTS_DB.RAW.AUTH_EVENTS_RAW AS
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
        $1:RECORD_METADATA:topic::VARCHAR(128),
        $1:RECORD_METADATA:partition::NUMBER,
        $1:RECORD_METADATA:offset::NUMBER,
        CURRENT_TIMESTAMP()
    FROM TABLE(DATA_SOURCE(TYPE => 'STREAMING'))
)
```

### Column Mapping: JSON → SQL

| JSON Field | SQL Column | Type | Notes |
|-----------|-----------|------|-------|
| `env` | `ENV` | VARCHAR(16) | NOT NULL |
| `event_ts` | `EVENT_TS` | TIMESTAMP_NTZ | NOT NULL, cast from ISO string |
| `event_id` | `EVENT_ID` | VARCHAR(64) | NOT NULL, dedup key with env |
| `payment_id` | `PAYMENT_ID` | VARCHAR(64) | NOT NULL |
| `merchant_id` | `MERCHANT_ID` | VARCHAR(32) | NOT NULL |
| `merchant_name` | `MERCHANT_NAME` | VARCHAR(256) | Nullable |
| `region` | `REGION` | VARCHAR(8) | NOT NULL |
| `country` | `COUNTRY` | VARCHAR(4) | NOT NULL |
| `card_brand` | `CARD_BRAND` | VARCHAR(16) | NOT NULL |
| `issuer_bin` | `ISSUER_BIN` | VARCHAR(8) | NOT NULL |
| `payment_method` | `PAYMENT_METHOD` | VARCHAR(16) | NOT NULL |
| `amount` | `AMOUNT` | NUMBER(12,2) | NOT NULL |
| `currency` | `CURRENCY` | VARCHAR(4) | NOT NULL |
| `auth_status` | `AUTH_STATUS` | VARCHAR(16) | NOT NULL |
| `decline_code` | `DECLINE_CODE` | VARCHAR(32) | Nullable (null if approved) |
| `auth_latency_ms` | `AUTH_LATENCY_MS` | INTEGER | NOT NULL |
| *(RECORD_METADATA)* | `SOURCE_TOPIC` | VARCHAR(128) | Kafka topic name |
| *(RECORD_METADATA)* | `SOURCE_PARTITION` | INTEGER | Kafka partition number |
| *(RECORD_METADATA)* | `SOURCE_OFFSET` | BIGINT | Kafka offset |
| *(CURRENT_TIMESTAMP)* | `INGESTED_AT` | TIMESTAMP_NTZ | NOT NULL, Snowflake ingest time |

Additional columns in the table not populated by the pipe:
- `HEADERS` (VARIANT) — Kafka headers, nullable
- `PAYLOAD` (VARIANT) — Full JSON for replay/debugging, nullable

### Landing Table Properties

| Property | Value |
|----------|-------|
| Full name | `PAYMENTS_DB.RAW.AUTH_EVENTS_RAW` |
| Total columns | 22 (20 from pipe + 2 nullable debug columns) |
| Schema evolution | Disabled |
| Data retention | 14 days |
| Environment isolation | Logical via `env` column (not separate tables) |

### Auth & Role
- **Role:** `PAYMENTS_INGEST_ROLE`
- **Auth:** Key-pair authentication (private key via env var)
- **Grants:** INSERT + SELECT on `AUTH_EVENTS_RAW`, OPERATE + MONITOR on pipe

### Why the Pipe Lives in Terraform (Not schemachange)

The pipe is stable infrastructure. `CREATE OR REPLACE PIPE` would drop and recreate the pipe, invalidating the HP connector's active streaming channel (non-retryable `ERR_PIPE_DOES_NOT_EXIST_OR_NOT_AUTHORIZED`). Terraform's `CREATE PIPE IF NOT EXISTS` is idempotent and safe. See `terraform/pipes.tf` header comments for the full rationale and the connector restart procedure if the definition must change.

### Latency at This Hop
**5-10 seconds** — Snowpipe Streaming via HP connector.

---

## Hop 2b: Kafka → Snowflake RAW (Fallback Path — Python Relay)

### Source Files
- `fallback_ingest/relay.py` — Consumer loop with batch flush
- `fallback_ingest/sf_client.py` — Snowflake `write_pandas` batch writer
- `fallback_ingest/config.py` — Environment configuration

### When Used
Activated if the HP connector is unavailable (e.g., preview access not granted, connector in FAILED state). Same landing table, different consumer group.

### Consumer Configuration

From `fallback_ingest/relay.py:23-33`:

```python
Consumer({
    "bootstrap.servers": KAFKA_BOOTSTRAP_SERVERS,
    "group.id": "snowflake-fallback-relay",
    "auto.offset.reset": "earliest",
    "enable.auto.commit": False,
})
```

### Batch Write Logic

1. Poll Kafka for messages (1s timeout)
2. Parse JSON, inject Kafka metadata (`source_topic`, `source_partition`, `source_offset`)
3. Accumulate in buffer
4. Flush when buffer reaches `BATCH_SIZE` (default 1,000 rows) or `BATCH_TIMEOUT` (default 5.0s)
5. Write via `snowflake.connector.pandas_tools.write_pandas` to `AUTH_EVENTS_RAW`
6. Commit Kafka offsets synchronously after successful write

### Connection

| Config | Default |
|--------|---------|
| Warehouse | `PAYMENTS_ADMIN_WH` |
| Role | `PAYMENTS_INGEST_ROLE` |
| Auth | Key-pair |
| Database/Schema | `PAYMENTS_DB.RAW` |

### Columns Written

The relay populates 19 columns (same as pipe mapping minus `HEADERS`, `PAYLOAD`, and `INGESTED_AT` which defaults):

```python
COLUMNS = [
    "env", "event_ts", "event_id", "payment_id",
    "merchant_id", "merchant_name", "region", "country",
    "card_brand", "issuer_bin", "payment_method",
    "amount", "currency", "auth_status", "decline_code",
    "auth_latency_ms", "source_topic", "source_partition", "source_offset",
]
```

### Latency at This Hop
**1-3 minutes** — batch accumulation + `write_pandas` staging + COPY INTO.

---

## Hop 3: RAW → SERVE (Interactive Tables)

### Source File
- `schemachange/migrations/V1.2.0__create_interactive_tables.sql`

### Architecture

Two interactive tables in `PAYMENTS_DB.SERVE` are materialized from `RAW.AUTH_EVENTS_RAW`:

- `PAYMENTS_REFRESH_WH` (standard, XSMALL) materializes the data every 60 seconds
- `PAYMENTS_INTERACTIVE_WH` (interactive, XSMALL) serves queries from the dashboard

Interactive tables support **INSERT OVERWRITE only** — no UPDATE or DELETE. They cannot be sources for streams or other dynamic tables.

### IT_AUTH_MINUTE_METRICS (22 columns)

**Purpose:** Pre-aggregated minute-level metrics for KPI cards, time series, breakdown, and latency histogram.

**Window:** 2 hours rolling (`event_ts >= DATEADD('HOUR', -2, CURRENT_TIMESTAMP())`)

**Deduplication:** `QUALIFY ROW_NUMBER() OVER (PARTITION BY env, event_id ORDER BY ingested_at DESC) = 1`

**Aggregation grain:** `event_minute` (truncated to minute) + all dimension columns

| Column | Type | Derivation |
|--------|------|-----------|
| `event_minute` | TIMESTAMP_NTZ | `DATE_TRUNC('MINUTE', event_ts)` |
| `env` | VARCHAR(16) | Passthrough |
| `merchant_id` | VARCHAR(32) | Passthrough |
| `merchant_name` | VARCHAR(256) | Passthrough |
| `region` | VARCHAR(8) | Passthrough |
| `country` | VARCHAR(4) | Passthrough |
| `card_brand` | VARCHAR(16) | Passthrough |
| `issuer_bin` | VARCHAR(8) | Passthrough |
| `payment_method` | VARCHAR(16) | Passthrough |
| `event_count` | INTEGER | `COUNT(*)` |
| `decline_count` | INTEGER | `COUNT_IF(auth_status = 'DECLINED')` |
| `approval_count` | INTEGER | `COUNT_IF(auth_status = 'APPROVED')` |
| `error_count` | INTEGER | `COUNT_IF(auth_status IN ('ERROR', 'TIMEOUT'))` |
| `latency_sum_ms` | BIGINT | `SUM(auth_latency_ms)` |
| `latency_count` | INTEGER | `COUNT(*)` |
| `latency_0_50ms` | INTEGER | `COUNT_IF(auth_latency_ms < 50)` |
| `latency_50_100ms` | INTEGER | `COUNT_IF(... >= 50 AND ... < 100)` |
| `latency_100_200ms` | INTEGER | `COUNT_IF(... >= 100 AND ... < 200)` |
| `latency_200_500ms` | INTEGER | `COUNT_IF(... >= 200 AND ... < 500)` |
| `latency_500_1000ms` | INTEGER | `COUNT_IF(... >= 500 AND ... < 1000)` |
| `latency_1000ms_plus` | INTEGER | `COUNT_IF(auth_latency_ms >= 1000)` |
| `total_amount` | NUMBER(18,2) | `SUM(amount)` |
| `avg_amount` | NUMBER(12,2) | `AVG(amount)` |

**Cluster key:** `(event_minute, env, merchant_id, region)`

**Design note:** Latency is stored as `latency_sum_ms` / `latency_count` rather than a pre-computed average to enable correct weighted reaggregation across dimension slices.

### IT_AUTH_EVENT_SEARCH (16 columns)

**Purpose:** Recent event-level records for failure drill-down and transaction search.

**Window:** 60 minutes rolling (`event_ts >= DATEADD('MINUTE', -60, CURRENT_TIMESTAMP())`)

**Deduplication:** Same QUALIFY pattern as metrics table.

| Column | Type | Derivation |
|--------|------|-----------|
| `event_ts` | TIMESTAMP_NTZ | Passthrough |
| `env` | VARCHAR(16) | Passthrough |
| `event_id` | VARCHAR(64) | Passthrough |
| `payment_id` | VARCHAR(64) | Passthrough |
| `merchant_id` | VARCHAR(32) | Passthrough |
| `merchant_name` | VARCHAR(256) | Passthrough |
| `region` | VARCHAR(8) | Passthrough |
| `country` | VARCHAR(4) | Passthrough |
| `card_brand` | VARCHAR(16) | Passthrough |
| `issuer_bin` | VARCHAR(8) | Passthrough |
| `payment_method` | VARCHAR(16) | Passthrough |
| `amount` | NUMBER(12,2) | Passthrough |
| `currency` | VARCHAR(4) | Passthrough |
| `auth_status` | VARCHAR(16) | Passthrough |
| `decline_code` | VARCHAR(32) | Passthrough |
| `auth_latency_ms` | INTEGER | Passthrough |

**Cluster key:** `(event_ts, env, merchant_id, auth_status)`

**Sort order:** `ORDER BY event_ts DESC`

### Latency at This Hop
**60 seconds** — `TARGET_LAG = '60 seconds'` for both interactive tables.

---

## Hop 3b: RAW → CURATED (dbt Dynamic Tables — Parallel Analytical Path)

### Source Files
- `dbt/models/curated/dt_auth_enriched.sql`
- `dbt/models/curated/dt_auth_hourly.sql`
- `dbt/models/curated/dt_auth_daily.sql`

### Architecture

This is a **parallel path, not in the hot serving path**. These dbt-managed dynamic tables refresh on `PAYMENTS_REFRESH_WH` and serve BI/ML workloads, not the live dashboard.

### dt_auth_enriched (target lag: 5 minutes)

**Source:** `RAW.AUTH_EVENTS_RAW` (7-day rolling window)

Adds computed enrichment columns to raw events:

| Computed Column | Logic |
|----------------|-------|
| `latency_tier` | FAST (<100ms), NORMAL (<300ms), SLOW (<1000ms), CRITICAL (>=1000ms) |
| `is_system_decline` | TRUE if `decline_code` in (ISSUER_UNAVAILABLE, SYSTEM_ERROR, TIMEOUT) |
| `value_tier` | STANDARD (<$100), MEDIUM (<$1000), HIGH (>=$1000) |
| `is_approved` | 1 if APPROVED, else 0 |
| `is_declined` | 1 if DECLINED, else 0 |

### dt_auth_hourly (target lag: 30 minutes)

**Source:** `dt_auth_enriched` (ref chain)

Aggregation grain: `event_hour` + env, merchant_id, merchant_name, region, country, card_brand, issuer_bin, payment_method

Metrics: event_count, approval_count, decline_count, error_count, latency_sum_ms, latency_count, total_amount, min_amount, max_amount, approval_rate

### dt_auth_daily (target lag: 1 hour)

**Source:** `dt_auth_enriched` (ref chain)

Aggregation grain: `event_date` + env, region, card_brand

Additional metrics beyond hourly: p95_latency_ms, p99_latency_ms, unique_merchants, unique_issuers

---

## Hop 4: Snowflake → FastAPI Backend

### Source Files
- `app/backend/main.py` — App entry point, lifespan, static file mount
- `app/backend/snowflake_client.py` — Dual connection pool manager
- `app/backend/routes/*.py` — 6 route modules
- `app/backend/queries/*.sql` — 6 SQL template files

### Dual Warehouse Routing

From `app/backend/snowflake_client.py`:

| Pool | Warehouse | Schema | Purpose |
|------|-----------|--------|---------|
| `interactive_pool` | `PAYMENTS_INTERACTIVE_WH` | `SERVE` | Dashboard queries on interactive tables |
| `standard_pool` | `PAYMENTS_ADMIN_WH` | `RAW` | Freshness check (`MAX(ingested_at)` on raw table) |

Interactive warehouses can **only** query interactive tables. The raw landing table is a standard table, requiring the standard warehouse for freshness queries.

### Authentication (Connection Priority)

1. **SPCS token** (production) — reads `/snowflake/session/token`, uses OAuth authenticator
2. **Key-pair** (local dev) — reads PEM from `SNOWFLAKE_PRIVATE_KEY_PATH`
3. **Password** (last resort) — `SNOWFLAKE_PASSWORD` env var

### Role
`PAYMENTS_APP_ROLE` — has SELECT on both SERVE and RAW schemas.

### API Endpoints and Data Sources

| Endpoint | Method | Source Table(s) | Warehouse | Purpose |
|----------|--------|-----------------|-----------|---------|
| `/api/v1/summary` | GET | `IT_AUTH_MINUTE_METRICS` + `AUTH_EVENTS_RAW` | Interactive + Standard | KPI cards with current vs previous window |
| `/api/v1/timeseries` | GET | `IT_AUTH_MINUTE_METRICS` | Interactive | Minute-bucketed line chart data |
| `/api/v1/breakdown` | GET | `IT_AUTH_MINUTE_METRICS` | Interactive | Top-N dimension drill-down with deltas |
| `/api/v1/events` | GET | `IT_AUTH_EVENT_SEARCH` | Interactive | Recent transactions (filterable) |
| `/api/v1/filters` | GET | `IT_AUTH_MINUTE_METRICS` | Interactive | Distinct values for dropdown population |
| `/api/v1/latency` | GET | `IT_AUTH_MINUTE_METRICS` + `IT_AUTH_EVENT_SEARCH` | Interactive | Histogram buckets + p50/p95/p99 |

### Query Details

**`/api/v1/summary`** (`queries/summary.sql`)
- Compares current window (`-time_range_minutes` to now) vs previous window (double the range)
- Computes: approval_rate, decline_rate, avg_latency_ms, event_count
- Weighted average: `SUM(latency_sum_ms) / NULLIF(SUM(latency_count), 0)`
- Freshness: `MAX(event_minute)` from SERVE + `MAX(ingested_at)` from RAW (via standard WH)
- Filters: env, merchant_id, region, card_brand

**`/api/v1/timeseries`** (`queries/timeseries.sql`)
- Groups by `event_minute`, returns up to 1,000 rows
- Metrics per minute: event_count, decline_rate, avg_latency_ms
- Filters: env, merchant_id, region, card_brand

**`/api/v1/breakdown`** (`queries/breakdown.sql`)
- Dynamic dimension parameter (merchant_id, region, country, card_brand, issuer_bin)
- Current vs previous period comparison with delta computation
- Returns top-N rows ordered by event count DESC
- Filters: env

**`/api/v1/events`** (`queries/events.sql`)
- Direct SELECT from `IT_AUTH_EVENT_SEARCH` (16 columns)
- Excludes `headers` and `payload` per display policy
- Ordered by `event_ts DESC`, limit configurable (default 100, max 500)
- Filters: auth_status, payment_id, env, merchant_id

**`/api/v1/filters`** (`queries/filters.sql`)
- `ARRAY_AGG(DISTINCT ...)` for 8 dimension columns
- 24-hour lookback window on `IT_AUTH_MINUTE_METRICS`

**`/api/v1/latency`** (`queries/latency.sql`)
- Part 1 (histogram): Sums 6 latency bucket columns from `IT_AUTH_MINUTE_METRICS`
- Part 2 (percentiles): `PERCENTILE_CONT(0.50/0.95/0.99)` from `IT_AUTH_EVENT_SEARCH`, capped at 10,000 rows
- Filters: env, merchant_id, region

### Latency at This Hop
**~100-200ms** per query on a warm interactive warehouse cache. Cold cache can be significantly slower (see warm-up procedure in `docs/RUNBOOK.md`).

---

## Hop 5: FastAPI → React Dashboard

### Source Files
- `app/frontend/src/App.tsx` — Layout and component composition
- `app/frontend/src/components/*.tsx` — 8 UI components
- `app/frontend/src/types/api.ts` — TypeScript interfaces

### Serving Architecture

The React app is built at Docker image build time (`npm run build`), and the resulting static files are served by FastAPI via `StaticFiles` mount at `/`. Both frontend and backend run in a single container on port 8080.

### Component → API Endpoint Mapping

| Component | API Endpoint | Data Displayed |
|-----------|-------------|----------------|
| `FilterBar` | `/api/v1/filters` | Dropdowns: env, merchant, region, country, card_brand, issuer_bin |
| `KPIStrip` | `/api/v1/summary` | Approval rate, decline rate, avg latency, event volume + deltas |
| `TimeSeriesChart` | `/api/v1/timeseries` | Line chart: event count, decline rate, latency over time |
| `BreakdownTable` | `/api/v1/breakdown` | Table: dimension drill-down with current vs previous deltas |
| `RecentFailures` | `/api/v1/events` | Table: recent declined/errored transactions |
| `LatencyPanel` | `/api/v1/latency` | Histogram (6 buckets) + p50/p95/p99 metrics |
| `CompareMode` | `/api/v1/summary` | Side-by-side comparison of two time periods |
| `FreshnessWidget` | `/api/v1/summary` | Visual indicator: raw ingest lag vs serve refresh lag |

### Dashboard Layout (12-column grid)

```
┌──────────────────────────────────────────────┐
│  FilterBar (full width)                       │
├──────────────────────────────────────────────┤
│  KPIStrip (full width)                        │
├──────────────────────────────────────────────┤
│  TimeSeriesChart (col-span-12)                │
├──────────────────────┬───────────────────────┤
│  BreakdownTable      │  RecentFailures       │
│  (col-span-8)        │  (col-span-4)         │
├──────────┬───────────┼───────────┬───────────┤
│ Compare  │  Latency  │ Freshness │           │
│ Mode     │  Panel    │ Widget    │           │
│ (col-4)  │  (col-4)  │  (col-4)  │           │
└──────────┴───────────┴───────────┴───────────┘
```

### Filter State

All components share a `DashboardFilters` state from `App.tsx`:

```typescript
{
  time_range: 15,       // minutes (default)
  env: null,            // environment filter
  merchant_id: null,
  region: null,
  card_brand: null,
  auth_status: null,
}
```

Filter changes propagate to all components simultaneously via React state.

---

## Schema Reference: Column Lineage

### Generator → RAW → SERVE

```
Generator JSON          RAW.AUTH_EVENTS_RAW        IT_AUTH_MINUTE_METRICS     IT_AUTH_EVENT_SEARCH
──────────────          ───────────────────        ──────────────────────     ────────────────────
env              →      ENV                  →     env                   →   env
event_ts         →      EVENT_TS             →     event_minute*             event_ts
event_id         →      EVENT_ID                   (dedup key)               event_id
payment_id       →      PAYMENT_ID                                           payment_id
merchant_id      →      MERCHANT_ID          →     merchant_id           →   merchant_id
merchant_name    →      MERCHANT_NAME        →     merchant_name         →   merchant_name
region           →      REGION               →     region                →   region
country          →      COUNTRY              →     country               →   country
card_brand       →      CARD_BRAND           →     card_brand            →   card_brand
issuer_bin       →      ISSUER_BIN           →     issuer_bin            →   issuer_bin
payment_method   →      PAYMENT_METHOD       →     payment_method        →   payment_method
amount           →      AMOUNT               →     total_amount*             amount
                                                    avg_amount*
currency         →      CURRENCY                                              currency
auth_status      →      AUTH_STATUS          →     event_count*              auth_status
                                                    decline_count*
                                                    approval_count*
                                                    error_count*
decline_code     →      DECLINE_CODE                                          decline_code
auth_latency_ms  →      AUTH_LATENCY_MS      →     latency_sum_ms*           auth_latency_ms
                                                    latency_count*
                                                    latency_0_50ms*
                                                    latency_50_100ms*
                                                    latency_100_200ms*
                                                    latency_200_500ms*
                                                    latency_500_1000ms*
                                                    latency_1000ms_plus*
(RECORD_METADATA) →     SOURCE_TOPIC
                        SOURCE_PARTITION
                        SOURCE_OFFSET
(CURRENT_TIMESTAMP) →   INGESTED_AT

* = aggregated / derived column
```

---

## Latency Budget

| Hop | From → To | Typical | Worst Case | Notes |
|-----|-----------|---------|------------|-------|
| 1 | Generator → Kafka | <1ms | <5ms | In-process produce |
| 2 | Kafka → RAW (HP) | 5-10s | 30s | Snowpipe Streaming |
| 2b | Kafka → RAW (fallback) | 1-3 min | 5 min | Batch relay |
| 3 | RAW → SERVE | 60s | 120s | Interactive table TARGET_LAG |
| 4 | SERVE → FastAPI | 100-200ms | 2-5s | Query on warm cache; cold can be minutes |
| 5 | FastAPI → Browser | <50ms | 200ms | Static assets, same container |
| **Total (HP path)** | **Generator → Dashboard** | **~65-75s** | **~3 min** | Cold cache is the outlier |
| **Total (fallback)** | **Generator → Dashboard** | **~2-4 min** | **~8 min** | Batch relay dominates |

### Freshness Monitoring

The `FreshnessWidget` component displays two freshness signals:

1. **Raw ingest lag** — `MAX(ingested_at)` from `RAW.AUTH_EVENTS_RAW` (queried via standard warehouse)
2. **Serve refresh lag** — `MAX(event_minute)` from `SERVE.IT_AUTH_MINUTE_METRICS`

The difference between these two signals shows how far behind the interactive tables are from raw ingest.

---

## Environment & Access Control

### Role Hierarchy

```
ACCOUNTADMIN
  └── SYSADMIN
        └── PAYMENTS_ADMIN_ROLE (Terraform, schemachange, dbt)
              ├── PAYMENTS_APP_ROLE     → Dashboard backend (SPCS)
              ├── PAYMENTS_INGEST_ROLE  → HP connector + fallback relay
              └── PAYMENTS_OPS_ROLE     → Dashboard viewers
```

### Role → Hop Assignment

| Hop | Component | Role | Warehouse | Access |
|-----|-----------|------|-----------|--------|
| 1 | Event Generator | N/A (Kafka only) | N/A | Kafka producer credentials |
| 2 | HP Connector | `PAYMENTS_INGEST_ROLE` | N/A (Snowpipe Streaming) | INSERT on RAW table, OPERATE on pipe |
| 2b | Fallback Relay | `PAYMENTS_INGEST_ROLE` | `PAYMENTS_ADMIN_WH` | INSERT on RAW table |
| 3 | Interactive Table Refresh | N/A (system) | `PAYMENTS_REFRESH_WH` | Automatic materialization |
| 4 | FastAPI Backend | `PAYMENTS_APP_ROLE` | `PAYMENTS_INTERACTIVE_WH` + `PAYMENTS_ADMIN_WH` | SELECT on SERVE + RAW |
| 3b | dbt Dynamic Tables | `PAYMENTS_ADMIN_ROLE` | `PAYMENTS_REFRESH_WH` | ALL on CURATED schema |

### Warehouse Assignment

| Warehouse | Type | Size | Auto-Suspend | Purpose |
|-----------|------|------|-------------|---------|
| `PAYMENTS_INTERACTIVE_WH` | Interactive | XSMALL | 24h | Dashboard queries on interactive tables |
| `PAYMENTS_REFRESH_WH` | Standard | XSMALL | 120s | Interactive table + dynamic table refresh |
| `PAYMENTS_ADMIN_WH` | Standard | XSMALL | 60s | Admin tasks, RAW freshness queries, fallback relay |
