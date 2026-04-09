"""
Page 4 — Resilience Demo: Fallback Relay Takeover

Visualises live event throughput from PAYMENTS_DB.RAW.AUTH_EVENTS_RAW.
Both the V4 HP Kafka connector and the Python fallback relay write to the
same table under separate consumer groups, so ingest continues through a
connector failure — this page makes that continuity visible.
"""

import time

import pandas as pd
import plotly.graph_objects as go
import streamlit as st
from streamlit_app import get_connection

st.set_page_config(
    page_title="Resilience Demo",
    page_icon="shield",
    layout="wide",
)
st.title("Resilience Demo: Fallback Relay Takeover")
st.caption(
    "Both the V4 HP Kafka connector and the Python fallback relay write to "
    "`PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V4` under separate consumer groups. "
    "Stop the connector, start the relay — data keeps flowing."
)

# ---------------------------------------------------------------------------
# Sidebar controls
# ---------------------------------------------------------------------------
with st.sidebar:
    st.subheader("Controls")
    window_min = st.slider("Time window (minutes)", 1, 15, 5)
    auto_refresh = st.checkbox("Auto-refresh", value=True)
    refresh_secs = st.slider(
        "Refresh interval (s)", 5, 60, 10, step=5, disabled=not auto_refresh
    )
    if st.button("Refresh now"):
        st.cache_data.clear()
        st.rerun()

# ---------------------------------------------------------------------------
# Data fetch
# ---------------------------------------------------------------------------

@st.cache_data(ttl=10, show_spinner=False)
def load_throughput(window_min: int) -> pd.DataFrame:
    conn = get_connection()
    with conn.cursor() as cur:
        cur.execute(
            f"""
            SELECT
                DATE_TRUNC('SECOND', EVENT_TS) AS second_bucket,
                COUNT(*)                        AS records_per_sec
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


@st.cache_data(ttl=10, show_spinner=False)
def load_pipeline_lag() -> int | None:
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


@st.cache_data(ttl=10, show_spinner=False)
def load_row_count(window_min: int) -> int:
    conn = get_connection()
    with conn.cursor() as cur:
        cur.execute(
            f"""
            SELECT COUNT(*)
            FROM PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V4
            WHERE EVENT_TS >= DATEADD('MINUTE', -{window_min}, SYSDATE())
            """
        )
        row = cur.fetchone()
    return row[0] if row else 0


with st.spinner("Loading..."):
    df = load_throughput(window_min)
    lag_ms = load_pipeline_lag()
    row_count = load_row_count(window_min)

# ---------------------------------------------------------------------------
# KPI strip
# ---------------------------------------------------------------------------
avg_rps = df["RECORDS_PER_SEC"].mean() if not df.empty else 0
lag_display = f"{lag_ms / 1000:,.1f} s" if lag_ms is not None else "N/A"

col1, col2, col3 = st.columns(3)
col1.metric(f"Total rows (last {window_min} min)", f"{row_count:,}")
col2.metric("Avg records / sec", f"{avg_rps:,.0f}")
col3.metric("Pipeline lag", lag_display)

st.divider()

# ---------------------------------------------------------------------------
# Throughput chart
# ---------------------------------------------------------------------------
st.subheader("Live Throughput — AUTH_EVENTS_RAW")

if df.empty:
    st.info(
        "No data in window. Confirm the generator and at least one ingest path "
        "(V4 connector or fallback relay) are running."
    )
else:
    fig = go.Figure(go.Scatter(
        x=df["SECOND_BUCKET"],
        y=df["RECORDS_PER_SEC"],
        mode="lines",
        line=dict(color="#00D4AA", width=2),
        fill="tozeroy",
        fillcolor="rgba(0,212,170,0.15)",
        name="records/sec",
    ))
    fig.update_layout(
        template="plotly_dark",
        yaxis_title="Records / sec",
        xaxis_title="Time (UTC)",
        showlegend=False,
        margin=dict(t=10, b=40),
        annotations=[
            dict(
                text="A gap here means both ingest paths were down simultaneously",
                xref="paper", yref="paper",
                x=0.01, y=0.97,
                showarrow=False,
                font=dict(size=11, color="#888"),
            )
        ],
    )
    st.plotly_chart(fig, use_container_width=True)

st.divider()

# ---------------------------------------------------------------------------
# Demo runbook
# ---------------------------------------------------------------------------
st.subheader("Demo Runbook")
st.caption(
    "Run these commands from the project root. "
    "Watch the throughput chart above — data should keep flowing throughout."
)

step1, step2, step3, step4, step5 = st.columns(5)

with step1:
    st.markdown("**1 — Confirm baseline**")
    st.markdown("Verify V4 connector is flowing:")
    st.code("make connector-status", language="bash")

with step2:
    st.markdown("**2 — Kill the connector**")
    st.markdown("Stop the V4 Kafka Connect worker:")
    st.code("docker-compose stop kafka-connect", language="bash")
    st.caption("Watch for a brief gap on the chart.")

with step3:
    st.markdown("**3 — Start the relay**")
    st.markdown("Activate the Python fallback relay:")
    st.code("make fallback-start", language="bash")
    st.caption("Data resumes within the first batch flush (~3 s).")

with step4:
    st.markdown("**4 — Verify relay**")
    st.markdown("Confirm relay is consuming:")
    st.code("make fallback-status", language="bash")

with step5:
    st.markdown("**5 — Restore V4**")
    st.markdown("Bring V4 back and stop the relay:")
    st.code(
        "docker-compose up -d kafka-connect\nmake fallback-stop",
        language="bash",
    )
    st.caption("V4 resumes from its own offset. Relay offset preserved for next drill.")

st.divider()

# ---------------------------------------------------------------------------
# Architecture note
# ---------------------------------------------------------------------------
with st.expander("How it works"):
    st.markdown(
        """
**Two independent ingest paths, one table.**

| Path | Consumer group | Client |
|---|---|---|
| V4 HP Kafka Connect | `snowflake-connector-group` | Rust Snowpipe Streaming HP |
| Python fallback relay | `snowflake-fallback-relay` | `write_pandas` via Python connector |

Both paths write to `PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V4`.

Because they use **separate consumer groups**, each maintains its own offset in Kafka.
The relay starts with `auto.offset.reset=latest`, so it picks up from *now* rather than
replaying backlog. When V4 comes back up it resumes from where it left off — no duplicate
processing.
        """
    )

# ---------------------------------------------------------------------------
# Auto-refresh
# ---------------------------------------------------------------------------
if auto_refresh:
    time.sleep(refresh_secs)
    st.cache_data.clear()
    st.rerun()
