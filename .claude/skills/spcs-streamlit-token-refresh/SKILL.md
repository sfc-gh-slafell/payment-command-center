# SPCS Streamlit — OAuth Token Expiry Fix

## Problem

When a Streamlit app runs in Snowpark Container Services (SPCS) and uses OAuth token auth,
the SPCS runtime rotates `/snowflake/session/token` roughly every hour. If the Snowflake
connector connection is cached with `@st.cache_resource` and **no TTL**, the cached
connection holds the original (now-expired) token indefinitely.

This produces:

```
snowflake.connector.errors.ProgrammingError: 390114 (08001):
Authentication token has expired. The user must authenticate again.
```

The traceback typically points into a `@st.cache_data`-wrapped query function, but the
root cause is one level up: the shared `get_connection()` resource returning a stale
connection.

## Root Cause

```python
# BROKEN — connection lives forever, token expires under it
@st.cache_resource(show_spinner=False)
def get_connection():
    return _connect()
```

`@st.cache_resource` with no TTL never evicts the connection object. The SPCS OAuth token
file is refreshed by the platform, but the cached connection still uses the old token
bytes that were read at startup.

## Fix

Add `ttl=3300` (55 minutes) so the connection is rebuilt before the 1-hour SPCS token
expiry window closes:

```python
@st.cache_resource(ttl=3300, show_spinner=False)  # 55 min — re-read SPCS token before 1 h expiry
def get_connection():
    return _connect()
```

`_connect()` reads the token file fresh each time it is called:

```python
_SPCS_TOKEN_PATH = "/snowflake/session/token"

def _connect():
    ...
    token = Path(_SPCS_TOKEN_PATH).read_text().strip()
    return snowflake.connector.connect(**params, token=token, authenticator="oauth")
```

Because `_connect()` always re-reads the file, the TTL-triggered cache miss automatically
picks up the rotated token.

## TTL Guidance

| SPCS token lifetime | Recommended ttl |
|---------------------|-----------------|
| ~1 hour (default)   | `3300` (55 min) |
| Custom (N seconds)  | `N * 0.9`       |

Do not set `ttl` shorter than necessary — every cache miss opens a new connection and
incurs a brief authentication round-trip.

## Non-SPCS auth modes

The TTL is harmless for key-pair and password auth: those credentials don't expire, so
recreating the connection every 55 minutes is slightly wasteful but functionally correct.
If the app runs exclusively outside SPCS you can remove the TTL, but leaving it in place
is safe and keeps the code portable.

## Files changed in this project

- `curated_analytics/streamlit_app.py` — `get_connection()` at line 88
