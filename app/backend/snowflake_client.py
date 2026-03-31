"""Snowflake connection manager with dual connection pools.

Architecture:
  - Interactive WH pool (PAYMENTS_INTERACTIVE_WH) — SERVE schema interactive tables
  - Standard WH pool (PAYMENTS_ADMIN_WH) — RAW schema standard table (freshness queries)
"""

import logging
import os
from pathlib import Path
from contextlib import contextmanager

import snowflake.connector

logger = logging.getLogger(__name__)

# Connection parameters
SNOWFLAKE_ACCOUNT = os.getenv("SNOWFLAKE_ACCOUNT", "")
SNOWFLAKE_USER = os.getenv("SNOWFLAKE_USER", "")
SNOWFLAKE_DATABASE = os.getenv("SNOWFLAKE_DATABASE", "PAYMENTS_DB")
SNOWFLAKE_ROLE = os.getenv("SNOWFLAKE_ROLE", "PAYMENTS_APP_ROLE")
SNOWFLAKE_PRIVATE_KEY_PATH = os.getenv("SNOWFLAKE_PRIVATE_KEY_PATH", "")

INTERACTIVE_WH = os.getenv("SNOWFLAKE_INTERACTIVE_WH", "PAYMENTS_INTERACTIVE_WH")
ADMIN_WH = os.getenv("SNOWFLAKE_ADMIN_WH", "PAYMENTS_ADMIN_WH")

SCHEMA_SERVE = os.getenv("SNOWFLAKE_SCHEMA_SERVE", "SERVE")
SCHEMA_RAW = os.getenv("SNOWFLAKE_SCHEMA_RAW", "RAW")

SPCS_TOKEN_PATH = "/snowflake/session/token"


def _get_spcs_token() -> str | None:
    """Read SPCS session token for container auth."""
    try:
        return Path(SPCS_TOKEN_PATH).read_text().strip()
    except FileNotFoundError:
        return None


def _load_private_key() -> bytes | None:
    """Load PEM private key for local development key-pair auth."""
    if not SNOWFLAKE_PRIVATE_KEY_PATH:
        return None
    try:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.backends import default_backend

        with open(SNOWFLAKE_PRIVATE_KEY_PATH, "rb") as f:
            private_key = serialization.load_pem_private_key(
                f.read(), password=None, backend=default_backend()
            )
        return private_key.private_bytes(
            encoding=serialization.Encoding.DER,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
    except Exception:
        logger.warning("Failed to load private key from %s", SNOWFLAKE_PRIVATE_KEY_PATH)
        return None


def _create_connection(
    warehouse: str, schema: str
) -> snowflake.connector.SnowflakeConnection:
    """Create a connection using SPCS token auth or key-pair auth fallback."""
    base_params = {
        "account": SNOWFLAKE_ACCOUNT,
        "database": SNOWFLAKE_DATABASE,
        "schema": schema,
        "warehouse": warehouse,
        "role": SNOWFLAKE_ROLE,
    }

    # Try SPCS token auth first (production)
    token = _get_spcs_token()
    if token:
        return snowflake.connector.connect(
            **base_params,
            token=token,
            authenticator="oauth",
        )

    # Fallback to key-pair auth (local development)
    private_key = _load_private_key()
    if private_key:
        return snowflake.connector.connect(
            **base_params,
            user=SNOWFLAKE_USER,
            private_key=private_key,
        )

    # Last resort: password auth
    return snowflake.connector.connect(
        **base_params,
        user=SNOWFLAKE_USER,
        password=os.getenv("SNOWFLAKE_PASSWORD", ""),
    )


class SnowflakeClient:
    """Dual-pool Snowflake client with warehouse routing."""

    def __init__(self):
        self._interactive_conn: snowflake.connector.SnowflakeConnection | None = None
        self._standard_conn: snowflake.connector.SnowflakeConnection | None = None

    @property
    def interactive_pool(self) -> snowflake.connector.SnowflakeConnection:
        """Connection to interactive warehouse for SERVE schema queries."""
        if self._interactive_conn is None or self._interactive_conn.is_closed():
            self._interactive_conn = _create_connection(INTERACTIVE_WH, SCHEMA_SERVE)
        return self._interactive_conn

    @property
    def standard_pool(self) -> snowflake.connector.SnowflakeConnection:
        """Connection to standard/admin warehouse for RAW schema queries."""
        if self._standard_conn is None or self._standard_conn.is_closed():
            self._standard_conn = _create_connection(ADMIN_WH, SCHEMA_RAW)
        return self._standard_conn

    def execute_query(
        self, sql: str, params: dict | None = None, use_standard_wh: bool = False
    ) -> list[dict]:
        """Execute SQL and return results as list of dicts.

        Routes to standard warehouse when use_standard_wh=True (freshness queries).
        """
        conn = self.standard_pool if use_standard_wh else self.interactive_pool
        cur = conn.cursor(snowflake.connector.DictCursor)
        try:
            cur.execute(sql, params or {})
            return cur.fetchall()
        finally:
            cur.close()

    def health_check(self) -> dict:
        """Check connectivity of both connection pools."""
        status = {"interactive": "unknown", "standard": "unknown"}
        try:
            self.interactive_pool.cursor().execute("SELECT 1").fetchone()
            status["interactive"] = "ok"
        except Exception as e:
            status["interactive"] = f"error: {e}"
        try:
            self.standard_pool.cursor().execute("SELECT 1").fetchone()
            status["standard"] = "ok"
        except Exception as e:
            status["standard"] = f"error: {e}"
        return status

    def close(self):
        """Close both connections."""
        for conn in (self._interactive_conn, self._standard_conn):
            if conn and not conn.is_closed():
                conn.close()

    @contextmanager
    def lifespan(self):
        """Context manager for connection lifecycle."""
        try:
            yield self
        finally:
            self.close()
