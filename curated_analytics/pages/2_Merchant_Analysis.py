"""
Page 2 — Merchant Analysis

Queries PAYMENTS_DB.CURATED.DT_AUTH_HOURLY to show merchant performance:
top 10 by volume, approval rate + latency table, and week-over-week comparison.
"""

import pandas as pd
import plotly.express as px
import streamlit as st
from streamlit_app import get_connection

st.set_page_config(page_title="Merchant Analysis", page_icon="🏪", layout="wide")
st.title("Merchant Analysis")
st.caption("Source: `PAYMENTS_DB.CURATED.DT_AUTH_HOURLY` · 30-min refresh lag")

# ---------------------------------------------------------------------------
# Data fetch
# ---------------------------------------------------------------------------

@st.cache_data(ttl=300, show_spinner="Loading merchant data...")
def load_merchant_summary() -> pd.DataFrame:
    conn = get_connection()
    with conn.cursor() as cur:
        cur.execute(
            """
            WITH this_week AS (
                SELECT
                    merchant_id,
                    merchant_name,
                    SUM(event_count)                                                      AS events_this_week,
                    SUM(approval_count) * 100.0 / NULLIF(SUM(event_count), 0)            AS approval_rate_this_week,
                    SUM(decline_count)  * 100.0 / NULLIF(SUM(event_count), 0)            AS decline_rate_this_week,
                    SUM(latency_sum_ms) / NULLIF(SUM(latency_count), 0)                  AS avg_latency_this_week,
                    SUM(total_amount)                                                     AS total_amount_this_week
                FROM PAYMENTS_DB.CURATED.DT_AUTH_HOURLY
                WHERE event_hour >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
                GROUP BY merchant_id, merchant_name
            ),
            last_week AS (
                SELECT
                    merchant_id,
                    SUM(event_count)                                                      AS events_last_week,
                    SUM(approval_count) * 100.0 / NULLIF(SUM(event_count), 0)            AS approval_rate_last_week
                FROM PAYMENTS_DB.CURATED.DT_AUTH_HOURLY
                WHERE event_hour >= DATEADD('DAY', -14, CURRENT_TIMESTAMP())
                  AND event_hour < DATEADD('DAY', -7, CURRENT_TIMESTAMP())
                GROUP BY merchant_id
            )
            SELECT
                t.merchant_id,
                t.merchant_name,
                t.events_this_week,
                t.approval_rate_this_week,
                t.decline_rate_this_week,
                t.avg_latency_this_week,
                t.total_amount_this_week,
                l.events_last_week,
                l.approval_rate_last_week,
                t.approval_rate_this_week - COALESCE(l.approval_rate_last_week, 0) AS approval_rate_delta
            FROM this_week t
            LEFT JOIN last_week l ON t.merchant_id = l.merchant_id
            ORDER BY t.events_this_week DESC
            LIMIT 20
            """
        )
        rows = cur.fetchall()
        cols = [desc[0] for desc in cur.description]
    return pd.DataFrame(rows, columns=cols)


df = load_merchant_summary()

if df.empty:
    st.warning("No merchant data found.")
    st.stop()

top10 = df.head(10)

# ---------------------------------------------------------------------------
# Top 10 merchants by volume
# ---------------------------------------------------------------------------
st.subheader("Top 10 Merchants by Transaction Volume (Last 7 Days)")
fig1 = px.bar(
    top10,
    x="MERCHANT_NAME",
    y="EVENTS_THIS_WEEK",
    color="APPROVAL_RATE_THIS_WEEK",
    color_continuous_scale="RdYlGn",
    range_color=[80, 100],
    labels={
        "MERCHANT_NAME": "Merchant",
        "EVENTS_THIS_WEEK": "Transactions",
        "APPROVAL_RATE_THIS_WEEK": "Approval Rate (%)",
    },
    template="plotly_dark",
)
fig1.update_layout(coloraxis_colorbar_title="Approval %")
st.plotly_chart(fig1, use_container_width=True)

# ---------------------------------------------------------------------------
# Performance table
# ---------------------------------------------------------------------------
st.subheader("Merchant Performance Metrics")
display_df = df[
    [
        "MERCHANT_NAME",
        "EVENTS_THIS_WEEK",
        "APPROVAL_RATE_THIS_WEEK",
        "DECLINE_RATE_THIS_WEEK",
        "AVG_LATENCY_THIS_WEEK",
        "APPROVAL_RATE_DELTA",
    ]
].copy()
display_df.columns = [
    "Merchant", "Events (7d)", "Approval % (7d)", "Decline % (7d)", "Avg Latency (ms)", "Approval Δ vs prev week"
]
display_df = display_df.round(
    {"Approval % (7d)": 1, "Decline % (7d)": 1, "Avg Latency (ms)": 0, "Approval Δ vs prev week": 1}
)

def _color_delta(val):
    if pd.isna(val):
        return ""
    return "color: green" if val > 0 else ("color: red" if val < 0 else "")

st.dataframe(
    display_df.style.map(_color_delta, subset=["Approval Δ vs prev week"]),
    use_container_width=True,
    hide_index=True,
)

# ---------------------------------------------------------------------------
# Week-over-week comparison for selected merchant
# ---------------------------------------------------------------------------
st.subheader("Week-over-Week Comparison")

selected = st.selectbox(
    "Select merchant",
    options=df["MERCHANT_ID"].tolist(),
    format_func=lambda mid: df.loc[df["MERCHANT_ID"] == mid, "MERCHANT_NAME"].iloc[0],
)

row = df[df["MERCHANT_ID"] == selected].iloc[0]
c1, c2, c3 = st.columns(3)
c1.metric(
    "Approval Rate",
    f"{row['APPROVAL_RATE_THIS_WEEK']:.1f}%",
    delta=f"{row['APPROVAL_RATE_DELTA']:+.1f}% vs last week" if pd.notna(row['APPROVAL_RATE_DELTA']) else None,
)
c2.metric(
    "Events This Week",
    f"{int(row['EVENTS_THIS_WEEK']):,}",
    delta=f"{int(row['EVENTS_THIS_WEEK'] - row['EVENTS_LAST_WEEK']):+,} vs last week"
    if pd.notna(row["EVENTS_LAST_WEEK"])
    else None,
)
c3.metric("Avg Latency", f"{row['AVG_LATENCY_THIS_WEEK']:.0f}ms")
