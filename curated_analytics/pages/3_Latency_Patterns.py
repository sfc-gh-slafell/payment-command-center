"""
Page 3 — Latency Patterns

Queries PAYMENTS_DB.CURATED.DT_AUTH_ENRICHED (event-level with latency_tier)
and DT_AUTH_DAILY (daily p95/p99) for SLA monitoring and regional analysis.
"""

import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import streamlit as st
from streamlit_app import get_connection

st.set_page_config(page_title="Latency Patterns", page_icon="⏱️", layout="wide")
st.title("Latency Patterns")
st.caption("Sources: `PAYMENTS_DB.CURATED.DT_AUTH_ENRICHED` · `DT_AUTH_DAILY` · 5–30 min refresh lag")

# ---------------------------------------------------------------------------
# Data fetch
# ---------------------------------------------------------------------------

@st.cache_data(ttl=300, show_spinner="Loading latency data...")
def load_latency_tier_distribution(days: int) -> pd.DataFrame:
    conn = get_connection()
    with conn.cursor() as cur:
        cur.execute(
            f"""
            SELECT
                latency_tier,
                COUNT(*) AS event_count
            FROM PAYMENTS_DB.CURATED.DT_AUTH_ENRICHED
            WHERE event_ts >= DATEADD('DAY', -{days}, CURRENT_TIMESTAMP())
            GROUP BY latency_tier
            ORDER BY
                CASE latency_tier
                    WHEN 'FAST'     THEN 1
                    WHEN 'NORMAL'   THEN 2
                    WHEN 'SLOW'     THEN 3
                    WHEN 'CRITICAL' THEN 4
                END
            """
        )
        rows = cur.fetchall()
        cols = [desc[0] for desc in cur.description]
    return pd.DataFrame(rows, columns=cols)


@st.cache_data(ttl=300, show_spinner="Loading regional data...")
def load_regional_heatmap(days: int) -> pd.DataFrame:
    conn = get_connection()
    with conn.cursor() as cur:
        cur.execute(
            f"""
            SELECT
                region,
                HOUR(event_ts)                           AS hour_of_day,
                AVG(auth_latency_ms)                     AS avg_latency_ms,
                COUNT(*)                                 AS event_count
            FROM PAYMENTS_DB.CURATED.DT_AUTH_ENRICHED
            WHERE event_ts >= DATEADD('DAY', -{days}, CURRENT_TIMESTAMP())
            GROUP BY region, HOUR(event_ts)
            ORDER BY region, hour_of_day
            """
        )
        rows = cur.fetchall()
        cols = [desc[0] for desc in cur.description]
    return pd.DataFrame(rows, columns=cols)


@st.cache_data(ttl=600, show_spinner="Loading daily percentiles...")
def load_daily_percentiles(days: int) -> pd.DataFrame:
    conn = get_connection()
    with conn.cursor() as cur:
        cur.execute(
            f"""
            SELECT
                event_date,
                SUM(latency_sum_ms) / NULLIF(SUM(latency_count), 0) AS avg_latency_ms,
                AVG(p95_latency_ms)                                  AS p95_latency_ms,
                AVG(p99_latency_ms)                                  AS p99_latency_ms
            FROM PAYMENTS_DB.CURATED.DT_AUTH_DAILY
            WHERE event_date >= DATEADD('DAY', -{days}, CURRENT_DATE())
            GROUP BY event_date
            ORDER BY event_date
            """
        )
        rows = cur.fetchall()
        cols = [desc[0] for desc in cur.description]
    return pd.DataFrame(rows, columns=cols)


# ---------------------------------------------------------------------------
# Filters
# ---------------------------------------------------------------------------
days = st.selectbox("Time window", [3, 7, 14, 30], index=1, format_func=lambda x: f"Last {x} days")

df_tiers = load_latency_tier_distribution(days)
df_heatmap = load_regional_heatmap(days)
df_daily = load_daily_percentiles(days)

if df_tiers.empty:
    st.warning("No latency data found. Verify DT_AUTH_ENRICHED is populated.")
    st.stop()

# ---------------------------------------------------------------------------
# Row 1: Tier distribution + p95/p99 time series
# ---------------------------------------------------------------------------
col1, col2 = st.columns([1, 2])

with col1:
    st.subheader("Latency Tier Distribution")
    tier_colors = {"FAST": "#00CC96", "NORMAL": "#636EFA", "SLOW": "#FFA15A", "CRITICAL": "#EF553B"}
    fig_pie = px.pie(
        df_tiers,
        names="LATENCY_TIER",
        values="EVENT_COUNT",
        color="LATENCY_TIER",
        color_discrete_map=tier_colors,
        template="plotly_dark",
        hole=0.35,
    )
    fig_pie.update_traces(textinfo="label+percent")
    st.plotly_chart(fig_pie, use_container_width=True)
    st.caption("FAST <100ms · NORMAL 100-300ms · SLOW 300ms-1s · CRITICAL >1s")

with col2:
    st.subheader("P95 / P99 Latency Over Time")
    if not df_daily.empty:
        fig_pct = go.Figure()
        fig_pct.add_trace(go.Scatter(
            x=df_daily["EVENT_DATE"], y=df_daily["AVG_LATENCY_MS"],
            name="Avg", line=dict(color="#636EFA"),
        ))
        fig_pct.add_trace(go.Scatter(
            x=df_daily["EVENT_DATE"], y=df_daily["P95_LATENCY_MS"],
            name="p95", line=dict(color="#FFA15A"),
        ))
        fig_pct.add_trace(go.Scatter(
            x=df_daily["EVENT_DATE"], y=df_daily["P99_LATENCY_MS"],
            name="p99", line=dict(color="#EF553B"),
        ))
        fig_pct.add_hline(y=1000, line_dash="dot", line_color="red", annotation_text="1s SLA")
        fig_pct.update_layout(
            template="plotly_dark",
            yaxis_title="Latency (ms)",
            xaxis_title="Date",
            legend=dict(orientation="h"),
        )
        st.plotly_chart(fig_pct, use_container_width=True)
    else:
        st.info("Daily percentile data not yet available.")

# ---------------------------------------------------------------------------
# Row 2: Regional heatmap (latency by region × hour)
# ---------------------------------------------------------------------------
st.subheader("Avg Latency by Region and Hour of Day")

if not df_heatmap.empty:
    pivot = df_heatmap.pivot_table(
        index="REGION", columns="HOUR_OF_DAY", values="AVG_LATENCY_MS", aggfunc="mean"
    )
    fig_heat = px.imshow(
        pivot,
        labels=dict(x="Hour of Day (UTC)", y="Region", color="Avg Latency (ms)"),
        color_continuous_scale="RdYlGn_r",
        aspect="auto",
        template="plotly_dark",
    )
    fig_heat.update_xaxes(dtick=1)
    st.plotly_chart(fig_heat, use_container_width=True)
    st.caption(
        "Insight: Identify regional/temporal latency patterns and peak-hour SLA risk. "
        "EU latency spike scenarios show clearly here."
    )
else:
    st.info("Regional heatmap data not yet available.")
