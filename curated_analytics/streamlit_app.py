"""
Payment Analytics Dashboard — entry point.

Consumes curated dbt dynamic tables (DT_AUTH_HOURLY, DT_AUTH_DAILY,
DT_AUTH_ENRICHED) to demonstrate the historical analytics path alongside
the real-time operational dashboard.
"""

import os
import snowflake.connector
import streamlit as st

# ---------------------------------------------------------------------------
# Page config
# ---------------------------------------------------------------------------
st.set_page_config(
    page_title="Payment Analytics",
    page_icon="📊",
    layout="wide",
    initial_sidebar_state="expanded",
)


# ---------------------------------------------------------------------------
# Snowflake connection (shared via session_state)
# ---------------------------------------------------------------------------

def _connect() -> snowflake.connector.SnowflakeConnection:
    """Create Snowflake connection from environment variables."""
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ.get("SNOWFLAKE_PASSWORD"),
        private_key=_load_private_key(),
        warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE", "PAYMENTS_REFRESH_WH"),
        database=os.environ.get("SNOWFLAKE_DATABASE", "PAYMENTS_DB"),
        schema="CURATED",
        role=os.environ.get("SNOWFLAKE_ROLE"),
        session_parameters={"QUERY_TAG": "payment-analytics-streamlit"},
    )


def _load_private_key():
    """Load private key bytes from file path env var, or return None."""
    path = os.environ.get("SNOWFLAKE_PRIVATE_KEY_PATH")
    if not path:
        return None
    from cryptography.hazmat.backends import default_backend
    from cryptography.hazmat.primitives.serialization import (
        Encoding, NoEncryption, PrivateFormat, load_pem_private_key,
    )
    passphrase = os.environ.get("SNOWFLAKE_PRIVATE_KEY_PASSPHRASE", "").encode() or None
    with open(path, "rb") as f:
        key = load_pem_private_key(f.read(), password=passphrase, backend=default_backend())
    return key.private_bytes(Encoding.DER, PrivateFormat.PKCS8, NoEncryption())


@st.cache_resource(show_spinner=False)
def get_connection() -> snowflake.connector.SnowflakeConnection:
    return _connect()


# ---------------------------------------------------------------------------
# Home page content
# ---------------------------------------------------------------------------

st.title("Payment Analytics Dashboard")
st.caption("Historical trend analysis powered by dbt dynamic tables")

st.markdown("""
This dashboard demonstrates the **curated analytics path** — the complement to the
real-time operational dashboard.

| | Ops Dashboard (Hot Path) | Analytics Dashboard (Curated Path) |
|---|---|---|
| **Data window** | Last 2 hours | Last 7–30 days |
| **Refresh** | 60-second interactive tables | 5–30 min dbt dynamic tables |
| **Serving layer** | Interactive warehouse | Standard warehouse |
| **Use case** | Live incident response | Trend detection, BI, ML |
| **Event granularity** | Event-level drill-down | Aggregated metrics |
""")

st.divider()

col1, col2, col3 = st.columns(3)

with col1:
    st.subheader("Hourly Trends")
    st.markdown(
        "Approval rates, volume, and latency over 7 days. "
        "Detect gradual degradation and seasonal patterns."
    )
    st.page_link("pages/1_Hourly_Trends.py", label="Open Hourly Trends →")

with col2:
    st.subheader("Merchant Analysis")
    st.markdown(
        "Top merchants by volume with week-over-week performance comparison. "
        "Identify outliers and track merchant health."
    )
    st.page_link("pages/2_Merchant_Analysis.py", label="Open Merchant Analysis →")

with col3:
    st.subheader("Latency Patterns")
    st.markdown(
        "Latency tier distribution, regional heatmaps, and p95/p99 tracking. "
        "SLA monitoring across time and geography."
    )
    st.page_link("pages/3_Latency_Patterns.py", label="Open Latency Patterns →")

st.divider()
st.caption(
    "Data source: `PAYMENTS_DB.CURATED.DT_AUTH_HOURLY` · `DT_AUTH_DAILY` · `DT_AUTH_ENRICHED` "
    "— dbt dynamic tables with 5–30 min refresh lag. Synthetic data only."
)
