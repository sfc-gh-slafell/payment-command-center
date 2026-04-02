"""
Page 4 — Connector Benchmark: V4 HP vs V3 Classic

Queries PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V4 (V4 HP) and
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
    "V4 HP: `PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V4` · "
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
        # Filter and bucket on EVENT_TS (per-row UTC timestamp from generator).
        # INGESTED_AT is set once per micro-partition write — NOT per row — so
        # per-row latency is not available in HP mode. Pipeline freshness is
        # computed separately via load_v4_pipeline_lag().
        # Use SYSDATE() (TIMESTAMP_NTZ UTC) for the threshold to avoid LTZ/NTZ
        # implicit conversion issues regardless of session timezone.
        cur.execute(
            f"""
            SELECT
                DATE_TRUNC('SECOND', EVENT_TS)  AS second_bucket,
                COUNT(*)                         AS records_per_sec
            FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V4
            WHERE EVENT_TS >= DATEADD('MINUTE', -{window_min}, SYSDATE())
            GROUP BY 1
            ORDER BY 1 ASC
            LIMIT 900
            """
        )
        rows = cur.fetchall()
        cols = [desc[0] for desc in cur.description]
    return pd.DataFrame(rows, columns=cols)


@st.cache_data(ttl=15, show_spinner=False)
def load_v4_pipeline_lag() -> int | None:
    """Return ms since the newest EVENT_TS visible in the V4 table.

    This is the only reliable latency proxy for HP Snowpipe Streaming:
    INGESTED_AT is a micro-partition open timestamp (set once per batch),
    so per-row ingest latency cannot be computed from it.
    """
    conn = get_connection()
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT DATEDIFF('millisecond', MAX(EVENT_TS), SYSDATE())
            FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V4
            """
        )
        row = cur.fetchone()
    return row[0] if row and row[0] is not None else None


@st.cache_data(ttl=15, show_spinner=False)
def load_v3_throughput(window_min: int) -> pd.DataFrame:
    conn = get_connection()
    with conn.cursor() as cur:
        # Filter and bucket on RECORD_CONTENT:event_ts (per-row UTC timestamp from the
        # generator), matching V4's EVENT_TS axis exactly. This gives a true apples-to-apples
        # throughput comparison: both queries answer "how many events with event-time T are
        # visible in Snowflake right now?"
        #
        # Using SnowflakeConnectorPushTime here would be misleading: if V3 is buffering
        # (e.g. buffer.flush.time=30s), it still shows a high push-time rps while flushing
        # but the events being pushed have event_ts values from 30+ seconds ago. Filtering
        # by event_ts exposes the staleness gap that push-time hides.
        #
        # SYSDATE() returns TIMESTAMP_NTZ in UTC — no LTZ/NTZ implicit conversion risk.
        cur.execute(
            f"""
            SELECT
                DATE_TRUNC('SECOND', RECORD_CONTENT:event_ts::TIMESTAMP_NTZ) AS second_bucket,
                COUNT(*)                                                       AS records_per_sec
            FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V3
            WHERE RECORD_CONTENT:event_ts::TIMESTAMP_NTZ >= DATEADD('MINUTE', -{window_min}, SYSDATE())
            GROUP BY 1
            ORDER BY 1 ASC
            LIMIT 900
            """
        )
        rows = cur.fetchall()
        cols = [desc[0] for desc in cur.description]
    return pd.DataFrame(rows, columns=cols)


@st.cache_data(ttl=15, show_spinner=False)
def load_v3_pipeline_lag() -> int | None:
    """Return ms since the newest event_ts visible in the V3 table.

    Matches load_v4_pipeline_lag() exactly: both measure how stale the newest
    queryable event is by event generation time (RECORD_CONTENT:event_ts for V3,
    EVENT_TS for V4). This is the correct apples-to-apples freshness comparison.

    Using MAX(SnowflakeConnectorPushTime) would be misleading when V3 is buffering:
    the push time reflects recent connector activity, not data freshness — V3 could
    be actively flushing 30-second-old events and still show near-zero push-time lag.
    """
    conn = get_connection()
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT DATEDIFF('millisecond',
                MAX(RECORD_CONTENT:event_ts::TIMESTAMP_NTZ),
                SYSDATE())
            FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V3
            """
        )
        row = cur.fetchone()
    return row[0] if row and row[0] is not None else None


with st.spinner("Loading benchmark data..."):
    df_v4 = load_v4_throughput(window_min)
    df_v3 = load_v3_throughput(window_min)
    v4_lag_ms = load_v4_pipeline_lag()
    v3_lag_ms = load_v3_pipeline_lag()

# ---------------------------------------------------------------------------
# KPI summary strip
# ---------------------------------------------------------------------------
v4_avg_rps = df_v4["RECORDS_PER_SEC"].mean() if not df_v4.empty else 0
v4_lag_display = f"{v4_lag_ms / 1000:,.1f} s" if v4_lag_ms is not None else "N/A"
v3_avg_rps = df_v3["RECORDS_PER_SEC"].mean() if not df_v3.empty else 0
v3_lag_display = f"{v3_lag_ms / 1000:,.1f} s" if v3_lag_ms is not None else "N/A"

col1, col2, col3, col4 = st.columns(4)
col1.metric("V4 HP — Avg rec/s", f"{v4_avg_rps:,.0f}")
col2.metric("V4 HP — Pipeline lag", v4_lag_display)
col3.metric("V3 Classic — Avg rec/s", f"{v3_avg_rps:,.0f}")
col4.metric("V3 Classic — Pipeline lag", v3_lag_display)

st.divider()

# ---------------------------------------------------------------------------
# V4 HP Advantages — Why upgrade from V3 Classic?
# ---------------------------------------------------------------------------
st.subheader("Why V4 HP?")
st.caption(
    "Both connectors handle moderate throughput equally well in this demo environment. "
    "V4 HP's advantages are architectural — they matter most at production scale and over time."
)

a1, a2, a3 = st.columns(3)

with a1:
    st.markdown("##### Throughput Ceiling")
    st.markdown(
        "V4 HP scales to **10 GB/s per table**. V3 Classic tops out at ~2,000 rps "
        "per task — limited by Java SDK per-row overhead. Beyond that ceiling, V3 "
        "accumulates Kafka consumer lag; V4 HP absorbs the load without falling behind."
    )

with a2:
    st.markdown("##### Predictable Billing")
    st.markdown(
        "V4 HP bills **per uncompressed GB ingested** — flat rate, scales linearly. "
        "V3 Classic bills per client connection + serverless compute credits, which "
        "grows unpredictably with throughput spikes and connection churn."
    )

with a3:
    st.markdown("##### Zero Buffer Tuning")
    st.markdown(
        "V4 HP manages micro-partition flushing internally. V3 requires hand-tuning "
        "`buffer.flush.time`, `buffer.count.records`, `buffer.size.bytes`, and "
        "`snowflake.streaming.max.client.lag` — parameters that interact in non-obvious "
        "ways and require re-tuning as throughput changes."
    )

a4, a5, a6 = st.columns(3)

with a4:
    st.warning(
        "**V3 Streaming Classic is deprecated.** "
        "Formal Snowflake announcement planned mid-2026, followed by an 18-month sunset. "
        "V4 HP is the endorsed replacement. Migration is manual — plan early."
    )

with a5:
    st.markdown("##### Rust Client — Lower Overhead")
    st.markdown(
        "V4 HP uses a Rust-based streaming client with a lower CPU and memory footprint "
        "than V3's Java Ingest SDK. At sustained high throughput, V3 JVM heap pressure "
        "becomes a tuning concern; V4 HP does not have this problem."
    )

with a6:
    st.markdown("##### Stable Lag Under Load")
    st.markdown(
        "V4 HP targets **5–10 s pipeline lag at any throughput** — this is a design "
        "constant of the HP architecture, not a low-load artifact. V3 Classic pipeline "
        "lag grows once rps exceeds its per-task ceiling. The numbers above reflect "
        "both connectors running below V3's ceiling; see lag divergence under load."
    )

st.divider()

# ---------------------------------------------------------------------------
# Row 1: Records per second — side-by-side
# ---------------------------------------------------------------------------
st.subheader("Records / Second")
rps_col1, rps_col2 = st.columns(2)

with rps_col1:
    st.markdown("**V4 HP (Snowpipe Streaming HPA)**")
    if df_v4.empty:
        st.info("No V4 data in window. Verify AUTH_EVENTS_RAW_V4 is receiving events.")
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
    "Both connectors show **pipeline freshness** = `SYSDATE() − MAX(event_ts)` — "
    "how long ago the newest generator-timestamped event became visible in Snowflake. "
    "V4 HP: `MAX(AUTH_EVENTS_RAW_V4.EVENT_TS)`. "
    "V3 Classic: `MAX(AUTH_EVENTS_RAW_V3.RECORD_CONTENT:event_ts)`. "
    "Same event clock, apples-to-apples. "
    "V4 HP targets 5–10 s (design constant of HP micro-partition flushing); "
    "V3 Classic lag grows with `buffer.flush.time` — currently 30 s."
)

lat_col1, lat_col2 = st.columns(2)

with lat_col1:
    st.markdown("**V4 HP — Pipeline freshness**")
    if v4_lag_ms is None:
        st.info("No V4 data available.")
    else:
        lag_sec = v4_lag_ms / 1000
        st.metric(
            label="Newest event visible in Snowflake",
            value=f"{lag_sec:,.1f} s ago",
        )
        st.caption(
            "HP Snowpipe Streaming flushes rows in micro-partition batches. "
            "`INGESTED_AT` is the partition-open timestamp — shared by all rows in a batch — "
            "so `INGESTED_AT − EVENT_TS` is meaningless for events that arrived after "
            "the partition opened. Pipeline freshness (`MAX(EVENT_TS)` → now) is the "
            "correct end-to-end visibility metric for this mode."
        )

with lat_col2:
    st.markdown("**V3 Classic — Pipeline freshness**")
    if v3_lag_ms is None:
        st.info("No V3 data available.")
    else:
        lag_sec = v3_lag_ms / 1000
        st.metric(
            label="Newest event visible in Snowflake",
            value=f"{lag_sec:,.1f} s ago",
        )
        st.caption(
            "V3 Snowpipe Streaming Classic buffers rows in the Java Ingest SDK before "
            "flushing to Snowflake. Pipeline freshness = `SYSDATE() − MAX(RECORD_CONTENT:event_ts)` — "
            "how long ago the newest generator-timestamped event became visible. "
            "With `buffer.flush.time=30 s`, V3 holds events for up to 30 s before flushing, "
            "giving consistent 30+ s lag vs V4 HP's 5–10 s design constant."
        )

# ---------------------------------------------------------------------------
# Auto-refresh
# ---------------------------------------------------------------------------
if auto_refresh:
    time.sleep(refresh_secs)
    st.cache_data.clear()
    st.rerun()
