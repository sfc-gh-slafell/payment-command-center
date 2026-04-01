"""
Page 4 — Connector Benchmark: V4 HP vs V3 Classic

Queries PAYMENTS_DB.RAW.AUTH_EVENTS_RAW (V4 HP) and
PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V3 (V3 Snowpipe Streaming Classic)
to show live side-by-side throughput and ingest latency.
"""

import time

import pandas as pd
import plotly.graph_objects as go
import streamlit as st
from streamlit_app import get_connection

st.set_page_config(
    page_title="Connector Benchmark",
    page_icon="⚡",
    layout="wide",
)
st.title("Connector Benchmark: V4 HP vs V3 Classic")
st.caption(
    "V4 HP: `PAYMENTS_DB.RAW.AUTH_EVENTS_RAW` · "
    "V3 Classic: `PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V3` · "
    "Same events dual-published for apples-to-apples comparison"
)

# ---------------------------------------------------------------------------
# Sidebar controls
# ---------------------------------------------------------------------------
with st.sidebar:
    st.subheader("Controls")
    window_min = st.slider("Time window (minutes)", 1, 15, 5)
    auto_refresh = st.checkbox("Auto-refresh", value=True)
    refresh_secs = st.slider(
        "Refresh interval (s)", 10, 120, 30, step=10, disabled=not auto_refresh
    )
    if st.button("Refresh now"):
        st.cache_data.clear()
        st.rerun()

# ---------------------------------------------------------------------------
# Data fetch
# ---------------------------------------------------------------------------

@st.cache_data(ttl=15, show_spinner=False)
def load_v4_throughput(window_min: int) -> pd.DataFrame:
    conn = get_connection()
    with conn.cursor() as cur:
        cur.execute(
            f"""
            SELECT
                DATE_TRUNC('SECOND', INGESTED_AT)                                    AS second_bucket,
                COUNT(*)                                                              AS records_per_sec,
                AVG(DATEDIFF('millisecond', EVENT_TS, INGESTED_AT))                  AS avg_latency_ms
            FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW
            WHERE INGESTED_AT >= DATEADD('MINUTE', -{window_min}, CURRENT_TIMESTAMP())
            GROUP BY 1
            ORDER BY 1 ASC
            LIMIT 900
            """
        )
        rows = cur.fetchall()
        cols = [desc[0] for desc in cur.description]
    return pd.DataFrame(rows, columns=cols)


@st.cache_data(ttl=15, show_spinner=False)
def load_v3_throughput(window_min: int) -> pd.DataFrame:
    conn = get_connection()
    with conn.cursor() as cur:
        cur.execute(
            f"""
            SELECT
                DATE_TRUNC('SECOND',
                    TO_TIMESTAMP(RECORD_METADATA:SnowflakeConnectorPushTime::BIGINT / 1000))
                                                                                     AS second_bucket,
                COUNT(*)                                                              AS records_per_sec,
                AVG(DATEDIFF('millisecond',
                    TO_TIMESTAMP(RECORD_METADATA:CreateTime::BIGINT / 1000),
                    TO_TIMESTAMP(RECORD_METADATA:SnowflakeConnectorPushTime::BIGINT / 1000)))
                                                                                     AS avg_latency_ms
            FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V3
            WHERE TO_TIMESTAMP(RECORD_METADATA:SnowflakeConnectorPushTime::BIGINT / 1000)
                >= DATEADD('MINUTE', -{window_min}, CURRENT_TIMESTAMP())
            GROUP BY 1
            ORDER BY 1 ASC
            LIMIT 900
            """
        )
        rows = cur.fetchall()
        cols = [desc[0] for desc in cur.description]
    return pd.DataFrame(rows, columns=cols)


with st.spinner("Loading benchmark data..."):
    df_v4 = load_v4_throughput(window_min)
    df_v3 = load_v3_throughput(window_min)

# ---------------------------------------------------------------------------
# KPI summary strip
# ---------------------------------------------------------------------------
v4_avg_rps = df_v4["RECORDS_PER_SEC"].mean() if not df_v4.empty else 0
v4_avg_lat = df_v4["AVG_LATENCY_MS"].mean() if not df_v4.empty else 0
v3_avg_rps = df_v3["RECORDS_PER_SEC"].mean() if not df_v3.empty else 0
v3_avg_lat = df_v3["AVG_LATENCY_MS"].mean() if not df_v3.empty else 0

col1, col2, col3, col4 = st.columns(4)
col1.metric("V4 HP — Avg rec/s", f"{v4_avg_rps:,.0f}")
col2.metric("V4 HP — Avg latency", f"{v4_avg_lat:,.0f} ms")
col3.metric("V3 Classic — Avg rec/s", f"{v3_avg_rps:,.0f}")
col4.metric("V3 Classic — Avg latency", f"{v3_avg_lat:,.0f} ms")

st.divider()

# ---------------------------------------------------------------------------
# Row 1: Records per second — side-by-side
# ---------------------------------------------------------------------------
st.subheader("Records / Second")
rps_col1, rps_col2 = st.columns(2)

with rps_col1:
    st.markdown("**V4 HP (Snowpipe Streaming HPA)**")
    if df_v4.empty:
        st.info("No V4 data in window. Verify AUTH_EVENTS_RAW is receiving events.")
    else:
        fig_v4_rps = go.Figure(go.Scatter(
            x=df_v4["SECOND_BUCKET"],
            y=df_v4["RECORDS_PER_SEC"],
            mode="lines",
            line=dict(color="#636EFA", width=2),
            fill="tozeroy",
            fillcolor="rgba(99,110,250,0.15)",
            name="V4 HP",
        ))
        fig_v4_rps.update_layout(
            template="plotly_dark",
            yaxis_title="Records / sec",
            xaxis_title="Time",
            showlegend=False,
            margin=dict(t=10, b=40),
        )
        st.plotly_chart(fig_v4_rps, use_container_width=True)

with rps_col2:
    st.markdown("**V3 Classic (Snowpipe Streaming Classic)**")
    if df_v3.empty:
        st.info("No V3 data in window. Verify AUTH_EVENTS_RAW_V3 is receiving events.")
    else:
        fig_v3_rps = go.Figure(go.Scatter(
            x=df_v3["SECOND_BUCKET"],
            y=df_v3["RECORDS_PER_SEC"],
            mode="lines",
            line=dict(color="#FFA15A", width=2),
            fill="tozeroy",
            fillcolor="rgba(255,161,90,0.15)",
            name="V3 Classic",
        ))
        fig_v3_rps.update_layout(
            template="plotly_dark",
            yaxis_title="Records / sec",
            xaxis_title="Time",
            showlegend=False,
            margin=dict(t=10, b=40),
        )
        st.plotly_chart(fig_v3_rps, use_container_width=True)

# ---------------------------------------------------------------------------
# Row 2: Ingest latency — side-by-side
# ---------------------------------------------------------------------------
st.subheader("Ingest Latency")
st.caption(
    "V4 HP: event generation (EVENT_TS) → table visibility (INGESTED_AT) — true end-to-end latency. "
    "V3 Classic: Kafka CreateTime → connector push (SnowflakeConnectorPushTime)."
)

lat_col1, lat_col2 = st.columns(2)

with lat_col1:
    st.markdown("**V4 HP — push-to-visible latency**")
    if df_v4.empty or df_v4["AVG_LATENCY_MS"].isna().all():
        st.info("Latency data not yet available for V4.")
    else:
        fig_v4_lat = go.Figure(go.Scatter(
            x=df_v4["SECOND_BUCKET"],
            y=df_v4["AVG_LATENCY_MS"],
            mode="lines",
            line=dict(color="#636EFA", width=2),
            name="V4 HP",
        ))
        fig_v4_lat.add_hline(
            y=10000, line_dash="dot", line_color="#EF553B",
            annotation_text="10s target"
        )
        fig_v4_lat.update_layout(
            template="plotly_dark",
            yaxis_title="Latency (ms)",
            xaxis_title="Time",
            showlegend=False,
            margin=dict(t=10, b=40),
        )
        st.plotly_chart(fig_v4_lat, use_container_width=True)

with lat_col2:
    st.markdown("**V3 Classic — create-to-push latency**")
    if df_v3.empty or df_v3["AVG_LATENCY_MS"].isna().all():
        st.info("Latency data not yet available for V3.")
    else:
        fig_v3_lat = go.Figure(go.Scatter(
            x=df_v3["SECOND_BUCKET"],
            y=df_v3["AVG_LATENCY_MS"],
            mode="lines",
            line=dict(color="#FFA15A", width=2),
            name="V3 Classic",
        ))
        fig_v3_lat.update_layout(
            template="plotly_dark",
            yaxis_title="Latency (ms)",
            xaxis_title="Time",
            showlegend=False,
            margin=dict(t=10, b=40),
        )
        st.plotly_chart(fig_v3_lat, use_container_width=True)

# ---------------------------------------------------------------------------
# Auto-refresh
# ---------------------------------------------------------------------------
if auto_refresh:
    time.sleep(refresh_secs)
    st.cache_data.clear()
    st.rerun()
