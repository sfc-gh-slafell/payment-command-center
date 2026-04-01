# Payment Analytics Dashboard

Streamlit application demonstrating the **curated analytics path** of the Payment Command Center.
Consumes dbt dynamic tables (`DT_AUTH_HOURLY`, `DT_AUTH_DAILY`, `DT_AUTH_ENRICHED`) for
historical trend analysis, merchant performance tracking, and latency SLA monitoring.

---

## Two-Path Architecture

```
                    Kafka → Snowpipe Streaming HP → AUTH_EVENTS_RAW
                                                          │
                         ┌────────────────────────────────┤
                         │                                │
                  ┌──────▼──────┐                ┌───────▼────────┐
                  │ Interactive │                │  dbt dynamic   │
                  │   Tables    │                │    tables      │
                  │ (60s lag)   │                │ (5–30 min lag) │
                  └──────┬──────┘                └───────┬────────┘
                         │                               │
                  ┌──────▼──────┐                ┌───────▼────────┐
                  │    Ops      │                │   Analytics    │
                  │  Dashboard  │                │   Dashboard    │
                  │ (this repo) │                │  (this app)    │
                  └─────────────┘                └────────────────┘
                  Real-time ops                  Historical BI/ML
                  Last 2 hours                   Last 7–30 days
```

| | Ops Dashboard | Analytics Dashboard |
|---|---|---|
| **Data source** | Interactive tables (SERVE schema) | dbt dynamic tables (CURATED schema) |
| **Refresh lag** | ~60 seconds | 5–30 minutes |
| **Warehouse** | PAYMENTS_INTERACTIVE_WH | PAYMENTS_REFRESH_WH |
| **Use case** | Live incident detection | Trend analysis, BI, ML feature engineering |
| **Time window** | Last 2 hours | Last 7–30 days |

---

## Pages

| Page | Data Source | Visualizations |
|------|-------------|----------------|
| Hourly Trends | `DT_AUTH_HOURLY` | Approval rate over 7d, volume by region, latency by card brand |
| Merchant Analysis | `DT_AUTH_HOURLY` | Top 10 merchants, performance table, week-over-week comparison |
| Latency Patterns | `DT_AUTH_ENRICHED` + `DT_AUTH_DAILY` | Tier distribution, regional heatmap, p95/p99 time series |

---

## Local Development

### Prerequisites

- Python 3.11+
- Snowflake credentials with SELECT on `PAYMENTS_DB.CURATED.*`

### Setup

```bash
cd curated_analytics
pip install -r requirements.txt
```

### Environment Variables

```bash
export SNOWFLAKE_ACCOUNT=sfpscogs-slafell-aws-2
export SNOWFLAKE_USER=SLAFELL
export SNOWFLAKE_PRIVATE_KEY_PATH=/path/to/rsa_key.p8
# OR: export SNOWFLAKE_PASSWORD=<password>

# Optional overrides (shown with defaults)
export SNOWFLAKE_DATABASE=PAYMENTS_DB
export SNOWFLAKE_WAREHOUSE=PAYMENTS_REFRESH_WH
```

### Run

```bash
streamlit run streamlit_app.py
```

Opens at `http://localhost:8501`

---

## SPCS Deployment

### Build and push image

```bash
# Build
docker build -t payment-analytics:v1 .

# Tag for Snowflake registry
docker tag payment-analytics:v1 \
  sfpscogs-slafell-aws-2.registry.snowflakecomputing.com/payments_db/app/dashboard_repo/payment-analytics:v1

# Login to Snowflake registry
snow spcs image-registry login

# Push
docker push \
  sfpscogs-slafell-aws-2.registry.snowflakecomputing.com/payments_db/app/dashboard_repo/payment-analytics:v1
```

### Create SPCS service

```sql
-- Create the analytics service
CREATE SERVICE PAYMENTS_DB.APP.PAYMENT_ANALYTICS
  IN COMPUTE POOL PAYMENTS_DASHBOARD_POOL
  FROM SPECIFICATION $$
  -- paste contents of spcs/analytics_service_spec.yaml
  $$
  EXTERNAL_ACCESS_INTEGRATIONS = ();

-- Check status
SELECT SYSTEM$GET_SERVICE_STATUS('PAYMENTS_DB.APP.PAYMENT_ANALYTICS');

-- Get public endpoint URL
SHOW ENDPOINTS IN SERVICE PAYMENTS_DB.APP.PAYMENT_ANALYTICS;
```

### Required grants

```sql
GRANT USAGE ON SERVICE PAYMENTS_DB.APP.PAYMENT_ANALYTICS TO ROLE PAYMENTS_APP_ROLE;
GRANT SELECT ON ALL DYNAMIC TABLES IN SCHEMA PAYMENTS_DB.CURATED TO ROLE PAYMENTS_APP_ROLE;
```

---

## Demo Narrative

> "The operational dashboard serves real-time incident response with sub-minute latency.
> For **historical analysis, trend detection, and business intelligence**, we have a parallel
> curated path powered by dbt dynamic tables. This analytics dashboard shows 7-day trends,
> merchant performance comparisons, and latency SLA monitoring — things that don't need
> refreshing every 60 seconds and benefit from richer aggregation."
