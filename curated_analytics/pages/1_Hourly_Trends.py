"""
Page 1 — Hourly Trends

Queries PAYMENTS_DB.CURATED.DT_AUTH_HOURLY to show 7-day trend lines
for approval rate, transaction volume, and average latency by region.
"""

import pandas as pd
import plotly.express as px
import streamlit as st
from streamlit_app import get_connection

st.set_page_config(page_title="Hourly Trends", page_icon="📈", layout="wide")
st.title("Hourly Trends")
st.caption("Source: `PAYMENTS_DB.CURATED.DT_AUTH_HOURLY` · 30-min refresh lag")

# ---------------------------------------------------------------------------
# Filters
# ---------------------------------------------------------------------------
col_a, col_b = st.columns([1, 3])
with col_a:
    days = st.selectbox("Time window", [3, 7, 14, 30], index=1, format_func=lambda x: f"Last {x} days")

# ---------------------------------------------------------------------------
# Data fetch
# ---------------------------------------------------------------------------

@st.cache_data(ttl=300, show_spinner="Loading hourly data...")
def load_hourly(days: int) -> pd.DataFrame:
    conn = get_connection()
    with conn.cursor() as cur:
        cur.execute(
            f"""
            SELECT
                event_hour,
                region,
                card_brand,
                SUM(event_count)                                                      AS total_events,
                SUM(approval_count) * 100.0 / NULLIF(SUM(event_count), 0)            AS approval_rate,
                SUM(decline_count)  * 100.0 / NULLIF(SUM(event_count), 0)            AS decline_rate,
                SUM(latency_sum_ms) / NULLIF(SUM(latency_count), 0)                  AS avg_latency_ms
            FROM PAYMENTS_DB.CURATED.DT_AUTH_HOURLY
            WHERE event_hour >= DATEADD('DAY', -{days}, CURRENT_TIMESTAMP())
            GROUP BY event_hour, region, card_brand
            ORDER BY event_hour
            """
        )
        rows = cur.fetchall()
        cols = [desc[0] for desc in cur.description]
    return pd.DataFrame(rows, columns=cols)


df = load_hourly(days)

if df.empty:
    st.warning("No data found. Verify dbt dynamic tables have been built in PAYMENTS_DB.CURATED.")
    st.stop()

# Hourly totals (all regions combined) for top-level charts
df_hourly = (
    df.groupby("EVENT_HOUR", as_index=False)
    .agg(
        total_events=("TOTAL_EVENTS", "sum"),
        approval_rate=("APPROVAL_RATE", "mean"),
        decline_rate=("DECLINE_RATE", "mean"),
        avg_latency_ms=("AVG_LATENCY_MS", "mean"),
    )
    .sort_values("EVENT_HOUR")
)

# ---------------------------------------------------------------------------
# Charts
# ---------------------------------------------------------------------------
st.subheader("Approval Rate")
fig1 = px.line(
    df_hourly,
    x="EVENT_HOUR",
    y="approval_rate",
    labels={"EVENT_HOUR": "Hour", "approval_rate": "Approval Rate (%)"},
    template="plotly_dark",
)
fig1.add_hline(y=95, line_dash="dot", line_color="green", annotation_text="95% target")
st.plotly_chart(fig1, use_container_width=True)

st.subheader("Transaction Volume by Region")
df_region = (
    df.groupby(["EVENT_HOUR", "REGION"], as_index=False)
    .agg(total_events=("TOTAL_EVENTS", "sum"))
    .sort_values("EVENT_HOUR")
)
fig2 = px.line(
    df_region,
    x="EVENT_HOUR",
    y="total_events",
    color="REGION",
    labels={"EVENT_HOUR": "Hour", "total_events": "Events", "REGION": "Region"},
    template="plotly_dark",
)
st.plotly_chart(fig2, use_container_width=True)

st.subheader("Average Latency by Card Brand")
df_brand = (
    df.groupby(["EVENT_HOUR", "CARD_BRAND"], as_index=False)
    .agg(avg_latency_ms=("AVG_LATENCY_MS", "mean"))
    .sort_values("EVENT_HOUR")
)
fig3 = px.line(
    df_brand,
    x="EVENT_HOUR",
    y="avg_latency_ms",
    color="CARD_BRAND",
    labels={"EVENT_HOUR": "Hour", "avg_latency_ms": "Avg Latency (ms)", "CARD_BRAND": "Card Brand"},
    template="plotly_dark",
)
fig3.add_hline(y=300, line_dash="dot", line_color="orange", annotation_text="300ms threshold")
st.plotly_chart(fig3, use_container_width=True)

st.caption(
    f"Showing {len(df_hourly)} hourly buckets over the last {days} days. "
    "Insight: Detect gradual degradation, seasonal patterns, and week-over-week trends."
)
