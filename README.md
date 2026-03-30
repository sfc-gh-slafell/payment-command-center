# Payment Authorization Command Center

[![Phase: Foundation](https://img.shields.io/badge/Phase-Foundation-blue)]()
[![Phase: Pipeline](https://img.shields.io/badge/Phase-Pipeline-yellow)]()
[![Phase: Dashboard](https://img.shields.io/badge/Phase-Dashboard-orange)]()
[![Demo Status](https://img.shields.io/badge/Status-Under_Development-red)]()
[![Data: Synthetic Only](https://img.shields.io/badge/Data-Synthetic_Only-green)]()

A real-time operational dashboard for payment authorization monitoring that demonstrates Snowflake's streaming data capabilities with sub-minute latency serving. This is a **demonstration project** built to showcase Snowflake's modern data streaming, serving, and application hosting features for payment operations teams and platform engineers.

---

## Table of Contents

- [Project Overview](#project-overview)
- [Key Features](#key-features)
- [Architecture Overview](#architecture-overview)
- [Technology Stack](#technology-stack)
- [Project Status](#project-status)
- [Getting Started](#getting-started)
- [Repository Structure](#repository-structure)
- [Development Workflow](#development-workflow)
- [Demo Scenarios](#demo-scenarios)
- [Key Design Decisions](#key-design-decisions)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [License](#license)

---

## Project Overview

Payment Authorization Command Center is a production-credible demonstration of real-time payment authorization monitoring using Snowflake's streaming and interactive serving capabilities.

**What it demonstrates:**
- Kafka-originated card authorization events streaming into Snowflake via **Snowpipe Streaming HP** (high-performance architecture)
- Sub-minute end-to-end latency from event generation to dashboard visualization
- Interactive tables and interactive warehouses for low-latency serving
- Multi-environment monitoring (dev, preprod, prod) with logical separation
- Scenario-driven incident injection for realistic demo experiences
- Containerized React application running in **Snowpark Container Services (SPCS)**

**Target Audience:**
- Platform engineering teams evaluating Snowflake's streaming ingest capabilities
- Payment operations teams needing sub-minute visibility into authorization health
- Demo audiences where the system must feel production-credible rather than synthetic

**Critical Note:** This project uses **SYNTHETIC DATA ONLY**. No real payment data, cardholder information, or PCI-sensitive data is stored or processed.

---

## Key Features

### Real-Time Monitoring
- **Sub-minute serving latency**: 60-second TARGET_LAG on interactive tables, 5-10 second ingest latency
- **Live KPI dashboard**: Approval rates, decline rates, average latency, event volume
- **Multi-dimensional drill-down**: Merchant, region, issuer BIN, card brand, decline code
- **Recent failures panel**: Real-time visibility into declined and errored transactions
- **Freshness tracking**: Separate indicators for raw ingest heartbeat and serving layer freshness

### Multi-Environment Support
- **Logical environment separation**: dev, preprod, prod within a single Snowflake account
- **Shared raw landing table** with `env` field for environment filtering
- **Cross-environment dashboards** without database switching
- **Independent scenario injection** per environment

### Scenario Injection
Four realistic incident scenarios for demo purposes:
- **Baseline**: Normal distribution (~95% approval, 50-150ms latency)
- **Issuer Outage**: Specific BIN range drops to 10% approval with `ISSUER_UNAVAILABLE` codes
- **Merchant Decline Spike**: Targeted merchant sees 60% decline rate with `DO_NOT_HONOR` codes
- **Latency Spike**: Regional latency jumps to 800-2000ms while approval rates stay normal

### Modern Architecture
- **Snowpipe Streaming HP**: Primary ingest path with 5-10 second latency
- **Interactive Tables**: Pre-aggregated metrics with 60-second TARGET_LAG
- **Interactive Warehouse**: Low-latency query serving optimized for dashboard workloads
- **SPCS-hosted application**: React frontend + Python API in Snowpark Container Services
- **Parallel curated path**: dbt-managed dynamic tables for BI and ML use cases

---

## Architecture Overview

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

### Component Overview

| Component | Technology | Purpose |
|---|---|---|
| **Event Generator** | Python, Faker, FastAPI | Produce realistic auth events with scenario injection |
| **Kafka** | Apache Kafka | Shared message bus (single topic, all environments) |
| **Kafka Connect** | Kafka Connect + Snowflake HP connector | Primary ingest into Snowflake (~10s latency) |
| **Fallback Ingest** | Python + snowflake-connector-python | Backup batch ingest path (~1-3 min latency) |
| **Landing Table** | Snowflake standard table | Shared raw event storage (all environments) |
| **Live Serving** | Interactive tables (TARGET_LAG=60s) | Pre-aggregated metrics + recent event search |
| **Interactive WH** | Snowflake interactive warehouse | Low-latency query serving |
| **Curated Path** | dbt + dynamic tables | Enrichment, hourly/daily rollups for BI/ML |
| **Dashboard** | React + Python (FastAPI), SPCS | Operational UI with env filtering |
| **Infrastructure** | Terraform | Account scaffolding, roles, warehouses, compute pools |
| **DDL Migrations** | schemachange | Tables, interactive tables, policies, service SQL |
| **CI/CD** | GitHub Actions + Snowflake CLI | Build, test, deploy |

---

## Technology Stack

### Data Platform
- **Snowflake**: Data warehouse and application platform
  - Snowpipe Streaming HP for real-time ingestion
  - Interactive tables and warehouses for low-latency serving
  - Dynamic tables for curated transformations
  - Snowpark Container Services (SPCS) for application hosting
- **Apache Kafka**: Event streaming platform
- **Kafka Connect**: Snowflake HP connector for Kafka integration

### Backend
- **Python 3.11+**: Application backend
- **FastAPI**: HTTP API framework
- **Uvicorn**: ASGI server
- **snowflake-connector-python**: Snowflake connectivity
- **confluent-kafka**: Kafka client library
- **Faker**: Synthetic data generation

### Frontend
- **React 18+**: UI framework
- **TypeScript**: Type-safe JavaScript
- **Tailwind CSS**: Utility-first styling
- **Recharts / Nivo**: Data visualization
- **TanStack Query**: Data fetching and caching

### Infrastructure & Tooling
- **Terraform**: Infrastructure as code
- **schemachange**: Database migration management
- **dbt**: Data transformation and testing
- **Snowflake CLI**: Deployment automation
- **Docker**: Container packaging
- **GitHub Actions**: CI/CD automation

---

## Project Status

This project is under active development. Current progress is organized into four phases with 28 open issues:

### Phase 0: Foundation (7 issues) 🔴 **CRITICAL**
*Must-have foundation — account-level infrastructure and core data pipeline*

- [ ] [#1](../../issues/1) Terraform: account infrastructure
- [ ] [#2](../../issues/2) Terraform: SPCS compute pool and image repo
- [ ] [#3](../../issues/3) schemachange: raw landing table DDL and grants
- [ ] [#4](../../issues/4) schemachange: interactive tables and warehouse association
- [ ] [#5](../../issues/5) Repository skeleton and dev tooling
- [ ] [#6](../../issues/6) Kafka topic creation and configuration
- [ ] [#7](../../issues/7) Kafka Connect HP connector config and deployment

### Phase 1: Pipeline (8 issues)
Event generation, ingestion, and backend API:
- [#8](../../issues/8) Event generator: project scaffold and Kafka producer
- [#9](../../issues/9) Event generator: scenario profiles and control API
- [#10](../../issues/10) Fallback ingest relay (Python batch)
- [#11](../../issues/11) Backend API: Snowflake client and dual connection pools
- [#12](../../issues/12) Backend API: SQL query templates
- [#13](../../issues/13) Backend API: route handlers and Pydantic models
- [#14](../../issues/14) Backend API: latency endpoint and freshness logic
- [#15](../../issues/15) End-to-end pipeline validation

### Phase 2: Dashboard (8 issues)
Frontend UI components and SPCS deployment:
- [#16](../../issues/16) Frontend: project scaffold, Tailwind, API types
- [#17](../../issues/17) Frontend: FilterBar and KPIStrip components
- [#18](../../issues/18) Frontend: TimeSeriesChart component
- [#19](../../issues/19) Frontend: BreakdownTable and RecentFailures components
- [#20](../../issues/20) Frontend: CompareMode, LatencyPanel, FreshnessWidget
- [#21](../../issues/21) Multi-stage Dockerfile and SPCS service spec
- [#22](../../issues/22) SPCS deployment and service creation
- [#23](../../issues/23) Scenario testing and dashboard validation

### Phase 3: Polish (4 issues)
Curated transformations, CI/CD, and documentation:
- [#24](../../issues/24) dbt: project setup and source definitions
- [#25](../../issues/25) dbt: curated dynamic table models and tests
- [#26](../../issues/26) GitHub Actions: CI workflow
- [#27](../../issues/27) GitHub Actions: CD workflow
- [#28](../../issues/28) Demo runbook and warm-up playbook

**Current Focus:** Foundation infrastructure setup (Phase 0)

---

## Getting Started

### Prerequisites

**Snowflake Requirements:**
- Snowflake account with ACCOUNTADMIN access (or equivalent privileges)
- **Interactive tables and warehouses** enabled (available in selected AWS regions only)
- **Snowpark Container Services (SPCS)** enabled
- **Snowpipe Streaming HP connector** preview access (December 2025 public preview)
  - Note: Selected accounts only — fallback batch ingest path available if unavailable
- Key-pair authentication configured for service accounts

**Development Tools:**
- **Python** >= 3.11
- **Node.js** >= 18 and npm
- **Docker** and Docker Compose
- **Terraform** >= 1.5.0
- **Snowflake CLI** (`snow` command)
- **dbt-core** with dbt-snowflake adapter (dynamic table support)
- **Git**

**External Infrastructure:**
- **Apache Kafka** cluster (self-managed or Confluent Cloud)
- **Kafka Connect** cluster with Snowflake HP connector v4.x installed
- Network connectivity between Kafka Connect and Snowflake (same cloud region recommended)

### Quick Start

```bash
# 1. Clone the repository
git clone <repository-url>
cd payment-command-center

# 2. Set up Snowflake infrastructure (Terraform)
cd terraform
terraform init
terraform plan
terraform apply  # Creates database, schemas, warehouses, compute pools, roles

# 3. Deploy database objects (schemachange)
cd ../schemachange
schemachange deploy -c schemachange-config.yml  # Creates tables, interactive tables

# 4. Create Kafka topic (24 partitions, 72h retention)
kafka-topics --create --topic payments.auth \
  --partitions 24 \
  --replication-factor 3 \
  --config retention.ms=259200000

# 5. Deploy Kafka Connect connector (or start fallback relay)
# Option A: Kafka Connect HP connector (primary path, ~10s latency)
curl -X POST http://kafka-connect:8083/connectors \
  -H "Content-Type: application/json" \
  -d @kafka-connect/shared.json

# Option B: Python fallback relay (~1-3 min latency)
cd ../fallback_ingest
docker build -t fallback-relay .
docker run -d fallback-relay

# 6. Start event generator with scenario control API
cd ../generator
docker build -t payment-generator .
docker run -d -p 8000:8000 payment-generator

# 7. Build and deploy dashboard to SPCS
cd ../app
docker build -t payments-command-center .
docker tag payments-command-center \
  <org>-<account>.registry.snowflakecomputing.com/payments_db/app/dashboard_repo/payments-command-center:latest
docker push <org>-<account>.registry.snowflakecomputing.com/payments_db/app/dashboard_repo/payments-command-center:latest

# Deploy SPCS service
cd ../spcs
snow spcs service deploy --config snowflake.yml

# 8. Resume interactive warehouse and warm up cache (CRITICAL for demos)
# Must be resumed at least 1 hour before demo for cache warm-up
snow sql -q "ALTER WAREHOUSE PAYMENTS_INTERACTIVE_WH RESUME;"
snow sql -q "SELECT COUNT(*) FROM PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS WHERE event_minute >= DATEADD('HOUR', -2, CURRENT_TIMESTAMP());"
snow sql -q "SELECT COUNT(*) FROM PAYMENTS_DB.SERVE.IT_AUTH_EVENT_SEARCH WHERE event_ts >= DATEADD('MINUTE', -60, CURRENT_TIMESTAMP());"

# 9. Run curated pipeline (dbt - optional for live dashboard)
cd ../dbt
dbt deps
dbt run    # Creates dynamic tables for BI/ML use cases
dbt test   # Validates data quality
```

**Important Pre-Demo Steps:**
1. **Resume interactive warehouse** at least 1 hour before demo (cache warm-up required)
2. **Run warm-up queries** against both interactive tables
3. **Verify data flow**: Generator → Kafka → Snowflake → Dashboard
4. **Test scenario injection** via event generator control API

---

## Repository Structure

```text
payment-command-center/
├── .github/
│   └── workflows/          # GitHub Actions CI/CD workflows
├── terraform/              # Infrastructure as code
│   ├── database.tf         # PAYMENTS_DB (shared database)
│   ├── schemas.tf          # RAW, SERVE, CURATED, APP schemas
│   ├── warehouses.tf       # Interactive WH, Refresh WH, Admin WH
│   ├── compute_pools.tf    # SPCS compute pool
│   ├── roles.tf            # Role hierarchy
│   └── grants.tf           # Privilege grants
├── schemachange/           # Database migrations
│   └── migrations/         # Versioned SQL migration scripts
├── dbt/                    # Data transformation
│   ├── models/
│   │   ├── staging/        # Source definitions
│   │   └── curated/        # Dynamic table models
│   └── tests/              # Data quality tests
├── generator/              # Event generator
│   ├── main.py             # FastAPI control server
│   ├── producer.py         # Kafka producer
│   ├── scenarios.py        # Scenario profiles
│   └── catalog.py          # Merchant/BIN/region catalog
├── kafka-connect/          # Kafka Connect configuration
│   └── shared.json         # HP connector config
├── fallback_ingest/        # Python batch ingest relay
│   ├── relay.py            # Kafka consumer -> Snowflake
│   └── sf_client.py        # Snowflake connection helpers
├── app/                    # Dashboard application
│   ├── backend/            # Python FastAPI backend
│   │   ├── routes/         # API route handlers
│   │   └── queries/        # SQL query templates
│   ├── frontend/           # React frontend
│   │   └── src/
│   │       └── components/ # UI components
│   └── Dockerfile          # Multi-stage container build
├── spcs/                   # SPCS deployment
│   ├── service_spec.yaml   # Service specification
│   └── snowflake.yml       # Snowflake CLI config
├── SPEC.md                 # Technical specification
└── README.md               # This file
```

---

## Development Workflow

### Working with Different Layers

**Infrastructure (Terraform):**
```bash
cd terraform
terraform plan
terraform apply
```

**Database Migrations (schemachange):**
```bash
cd schemachange
schemachange deploy -c schemachange-config.yml
```

**Data Transformations (dbt):**
```bash
cd dbt
dbt deps
dbt compile
dbt run
dbt test
```

**Event Generator:**
```bash
cd generator
python main.py
# In another terminal:
curl -X POST http://localhost:8000/scenario -d '{"profile": "issuer_outage", "duration_sec": 300}'
```

**Dashboard Development:**
```bash
# Backend
cd app/backend
uvicorn main:app --reload

# Frontend
cd app/frontend
npm run dev
```

**SPCS Deployment:**
```bash
cd spcs
snow spcs service deploy --config snowflake.yml
```

### Key Workflows

**1. Add a new interactive table:**
- Create migration in `schemachange/migrations/V{version}__description.sql`
- Add CLUSTER BY keys matching dashboard filter patterns
- Set TARGET_LAG = 60 seconds
- Associate with interactive warehouse in separate migration

**2. Add a new dashboard panel:**
- Create SQL query template in `app/backend/queries/`
- Add route handler in `app/backend/routes/`
- Create React component in `app/frontend/src/components/`
- Wire up to FilterBar context

**3. Add a new scenario:**
- Define scenario profile in `generator/scenarios.py`
- Update control API endpoint in `generator/main.py`
- Test with event generator control API

**4. Add a curated model:**
- Create dbt model in `dbt/models/curated/`
- Use `materialized='dynamic_table'` config
- Add data quality tests in model YAML

---

## Demo Scenarios

Four pre-configured incident scenarios demonstrate the dashboard's real-time monitoring capabilities:

### Baseline
Normal healthy traffic distribution:
- ~95% approval rate
- 50-150ms latency range
- Uniform merchant/region spread
- Realistic volume patterns

### Issuer Outage
Simulates issuer system unavailability:
- BIN range `411111` drops to 10% approval
- Decline code: `ISSUER_UNAVAILABLE`
- Affects specific card issuer globally
- Dashboard shows regional impact and BIN-level drill-down

### Merchant Decline Spike
Targeted merchant experiencing issues:
- Specific merchant sees 60% decline rate
- Decline code: `DO_NOT_HONOR`
- Other merchants unaffected
- Dashboard highlights merchant-specific anomaly

### Latency Spike
Regional network degradation:
- EU region latency jumps to 800-2000ms
- Approval rates remain normal (differentiates from outage)
- Other regions unaffected
- Latency panel shows distribution shift with p95/p99 spikes

**Recommended Demo Flow:**
1. **Baseline** (5 min) — establish healthy state, show ~95% approval, 50-150ms latency
2. **Issuer Outage** (5 min) — observe BIN-level failure spike in breakdown table and failures panel
3. **Return to Baseline** (2 min) — demonstrate recovery within ~60-90 seconds
4. **Latency Spike** (5 min) — show regional latency degradation in latency panel
5. **Emphasize Freshness Widget** throughout — raw data arrives in seconds, serving refreshes every 60s

**Triggering Scenarios via Control API:**
```bash
# Check current status
curl http://localhost:8000/status

# Activate issuer outage for 5 minutes
curl -X POST http://localhost:8000/scenario \
  -H "Content-Type: application/json" \
  -d '{"profile": "issuer_outage", "duration_sec": 300}'

# Activate merchant decline spike
curl -X POST http://localhost:8000/scenario \
  -H "Content-Type: application/json" \
  -d '{"profile": "merchant_decline_spike", "duration_sec": 300}'

# Activate latency spike
curl -X POST http://localhost:8000/scenario \
  -H "Content-Type: application/json" \
  -d '{"profile": "latency_spike", "duration_sec": 300}'

# Return to baseline immediately
curl -X DELETE http://localhost:8000/scenario

# Adjust event rate (events per second)
curl -X POST http://localhost:8000/rate \
  -H "Content-Type: application/json" \
  -d '{"events_per_sec": 1000}'
```

**Dashboard Response Time:**
- Allow **60-90 seconds** for scenario effects to appear in dashboard
- Interactive tables refresh on 60-second TARGET_LAG
- Freshness widget shows exact raw ingest vs serving layer lag

---

## Operational Notes

### Interactive Warehouse Cache Warm-Up
**CRITICAL for demo success:**
- Interactive warehouses are created in **SUSPENDED** state
- Must **RESUME at least 1 hour before demo** for cache warm-up
- Cache warm-up time varies: minutes to ~1 hour depending on data volume
- **Minimum AUTO_SUSPEND is 86400 seconds (24 hours)** — warehouse runs continuously
- Cold cache = slow first queries (minutes) and poor demo experience

**Warm-up procedure:**
```sql
-- Resume warehouse (do this 1+ hour before demo)
ALTER WAREHOUSE PAYMENTS_INTERACTIVE_WH RESUME;

-- Run warm-up queries
SELECT COUNT(*), SUM(event_count), AVG(latency_sum_ms / NULLIF(latency_count, 0))
FROM PAYMENTS_DB.SERVE.IT_AUTH_MINUTE_METRICS
WHERE event_minute >= DATEADD('HOUR', -2, CURRENT_TIMESTAMP());

SELECT COUNT(*)
FROM PAYMENTS_DB.SERVE.IT_AUTH_EVENT_SEARCH
WHERE event_ts >= DATEADD('MINUTE', -60, CURRENT_TIMESTAMP());
```

### Troubleshooting Common Issues

**Dashboard shows no data:**
1. Check event generator is producing events: `curl http://localhost:8000/status`
2. Verify Kafka topic has messages: `kafka-console-consumer --topic payments.auth --from-beginning --max-messages 10`
3. Check connector status (if using HP connector): `curl http://kafka-connect:8083/connectors/auth-events-sink-payments/status`
4. Query raw table directly: `SELECT COUNT(*) FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW WHERE ingested_at >= DATEADD('MINUTE', -5, CURRENT_TIMESTAMP());`
5. Check interactive table refresh status: `SELECT * FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY('IT_AUTH_MINUTE_METRICS')) ORDER BY REFRESH_START_TIME DESC LIMIT 5;`

**Scenario changes not appearing:**
- Wait 60-90 seconds for interactive table refresh
- Check freshness widget for serving lag
- Verify scenario is active: `curl http://localhost:8000/status`
- Monitor raw table for new event patterns

**Slow dashboard queries:**
- Confirm interactive warehouse is RESUMED (not suspended)
- Run warm-up queries if recently resumed
- Check query history for execution times
- Verify CLUSTER BY keys align with filter patterns

**HP Connector issues (primary ingest path):**
- Check connector logs via Kafka Connect REST API
- Verify preview access to HP connector v4.x
- Switch to fallback Python relay if connector unavailable
- Fallback relay provides ~1-3 min latency (vs ~10s with HP connector)

---

## Key Design Decisions

### 1. No Dynamic Tables in the Hot Path

**Decision:** Do not put dynamic tables in front of interactive tables for live serving.

**Rationale:** Both dynamic tables and interactive tables have a minimum 60-second TARGET_LAG. Stacking them doubles the latency budget. Interactive tables are optimized serving structures, not ingest sinks.

**Pattern:**
```text
✅ Correct:  Kafka → Snowpipe Streaming HP → raw table → interactive tables
❌ Incorrect: Kafka → Snowpipe Streaming HP → raw table → dynamic table → interactive table
```

Dynamic tables are used in a **parallel curated path** for enrichment, longer retention, and BI/ML use cases, not in the live dashboard's critical path.

### 2. Environments as Data, Not Separate Streams

**Decision:** Use a single Kafka topic and single raw landing table with an `env` field for logical environment separation.

**Rationale:**
- Reduces operational overhead (one ingest pipeline vs. three)
- Simplifies Kafka Connect configuration (one connector, one target)
- Enables unified cross-environment dashboards without database switching
- Maintains demo simplicity while illustrating production patterns

**Trade-offs:**
- No physical isolation between environments at raw layer
- Shared blast radius if ingest fails
- Potential noisy neighbor issues

**Production Note:** In production systems, use separate Kafka topics (`payments.dev.auth`, `payments.preprod.auth`, `payments.prod.auth`) for blast-radius isolation, independent offset management, and per-environment access control. The shared-topic model is a deliberate demo simplification.

### 3. Primary vs. Fallback Ingest Path

**Primary Path:** Kafka Connect with Snowflake HP connector (preview)
- Native Kafka integration
- ~5-10 second ingest latency
- Auto-scaling and serverless compute
- Requires preview access

**Fallback Path:** Python relay using snowflake-connector-python
- Batch `PUT` + `COPY INTO` pattern
- ~1-3 minute ingest latency
- Guaranteed availability for demo continuity
- Same landing table schema as primary path

The fallback ensures demo viability if the HP connector preview is unavailable or unstable.

### 4. Dual Connection Pools for Backend

**Decision:** Backend maintains two separate Snowflake connection pools.

**Pools:**
1. **Interactive warehouse pool**: For dashboard queries against interactive tables
2. **Standard warehouse pool**: For freshness queries against raw standard table

**Rationale:** Interactive warehouses can only query interactive tables. The raw landing table is a standard table requiring a standard warehouse for access.

### 5. Statistical Correctness in Aggregations

**Decision:** Store `latency_sum_ms` and `latency_count` instead of pre-computed averages.

**Rationale:** Enables statistically correct weighted averages when combining multiple minute buckets or filtering dimensions. Percentile calculations require event-level data from the event search table.

---

## Documentation

- **[SPEC.md](./SPEC.md)** - Complete technical specification
  - Detailed component specifications
  - API contract documentation
  - Environment model and naming conventions
  - Change management toolchain
  - Constraints and operational risks

- **[requirements.md](./requirements.md)** - Original requirements and design rationale

- **[GitHub Issues](../../issues)** - Implementation tracking organized by phase

- **Inline Documentation:**
  - SQL migrations: `schemachange/migrations/`
  - dbt models: `dbt/models/` with YAML documentation
  - API routes: `app/backend/routes/` with docstrings
  - React components: `app/frontend/src/components/` with JSDoc

---

## Contributing

### Development Process

1. **Check existing issues:** Review [open issues](../../issues) organized by phase
2. **Create a branch:** Use naming pattern `phase-{n}/{issue-number}-{description}`
   ```bash
   git checkout -b phase-1/11-snowflake-client
   ```
3. **Follow coding standards:**
   - Python: PEP 8, type hints, docstrings
   - TypeScript: ESLint rules, type safety
   - SQL: Standard formatting, comments for complex logic
4. **Test your changes:** Run relevant test suites
5. **Submit a pull request:** Reference related issues

### Code Quality Standards

- **SQL:**
  - Use CTEs for complex queries
  - Add comments explaining business logic
  - Parameterize all user inputs (no string interpolation)
  - Include LIMIT clauses and time predicates

- **Python:**
  - Type hints on all functions
  - Docstrings for public APIs
  - Parameterized SQL queries (use `snowflake.connector` parameter binding)
  - Error handling with specific exception types

- **TypeScript/React:**
  - TypeScript strict mode enabled
  - Props interfaces for all components
  - Error boundaries for component failures
  - Accessibility attributes (ARIA labels)

### Testing Strategy

- **Unit tests:** Python backend, TypeScript utilities
- **Integration tests:** API endpoints, dbt models
- **End-to-end tests:** Dashboard workflows with scenario injection
- **Performance tests:** Query response times, interactive table refresh lag

---

## License

This project is a demonstration application for educational and evaluation purposes.

**Important Disclaimers:**
- This is a DEMO project with SYNTHETIC DATA ONLY
- No real payment data, cardholder information, or PCI-sensitive data
- Not intended for production use without significant security and compliance hardening
- Snowpipe Streaming HP connector is in preview (December 2025) and not production-ready

### Known Constraints and Limitations

**Interactive Tables & Warehouses:**
- Minimum TARGET_LAG is 60 seconds (cannot refresh faster)
- Interactive warehouses can only query interactive tables (not standard tables)
- Minimum AUTO_SUSPEND is 86400 seconds (24 hours) — continuous credit consumption
- Cache warm-up required after resume (minutes to ~1 hour)
- Interactive tables support INSERT OVERWRITE only (no UPDATE/DELETE DML)
- Cannot source streams or serve as base for dynamic tables

**SPCS (Snowpark Container Services):**
- Dashboard access requires Snowflake users in same account (no external viewer access in V1)
- Public endpoints require BIND SERVICE ENDPOINT privilege (verify current docs)
- Cannot run CALL commands or use `->>` pipe operator from interactive warehouses

**Shared Topic/Table Model:**
- All environments share ingest pipeline — one connector outage affects all
- Mis-tagged `env` field could cause environment data mixing
- Noisy neighbor risk: one environment's volume spike impacts others
- **Production Note:** Real systems should use separate Kafka topics per environment for blast-radius isolation

**V1 Exclusions:**
- No late-arriving or out-of-order event handling (assumes timely arrival)
- No external viewer authentication (passive demo observers only)
- No multi-account federation (all environments in one account)
- No real cardholder data masking policies (synthetic data only)
- No cross-region replication or disaster recovery

### Production Hardening Requirements

For production use cases involving real payment data, the following must be added:
- [ ] **PCI Compliance**: Comprehensive controls for payment card industry standards
- [ ] **Data Masking**: Snowflake masking policies for sensitive fields (payment_id, issuer_bin)
- [ ] **Multi-Account Isolation**: Separate Snowflake accounts for environment blast-radius isolation
- [ ] **External Authentication**: OAuth or external IdP integration for dashboard access
- [ ] **Audit Logging**: Comprehensive access and query logging for compliance
- [ ] **Security Review**: Penetration testing and vulnerability scanning
- [ ] **Disaster Recovery**: Cross-region replication and recovery procedures
- [ ] **Load Testing**: Capacity planning for production event volumes
- [ ] **Monitoring & Alerting**: Production-grade observability and incident response
- [ ] **Data Retention**: Archival and retention policies compliant with regulations

---

## Contact & Support

For questions about this demonstration project:
- Review the [SPEC.md](./SPEC.md) for technical details
- Check [open issues](../../issues) for known limitations
- Consult Snowflake documentation for platform features

**Snowflake Resources:**
- [Snowpipe Streaming HP Documentation](https://docs.snowflake.com/en/user-guide/snowpipe-streaming)
- [Interactive Tables Documentation](https://docs.snowflake.com/en/user-guide/interactive)
- [SPCS Documentation](https://docs.snowflake.com/en/developer-guide/snowpark-container-services/overview)
- [Kafka HP Connector Documentation](https://docs.snowflake.com/en/connectors/kafkahp/about)

---

**Built to demonstrate modern real-time data applications on Snowflake.**
