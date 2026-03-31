"""
End-to-end integration tests for the Payment Authorization Command Center pipeline.

Validates the full flow: Event Generator → Kafka → Snowpipe Streaming HP →
Interactive Tables → Dashboard API.

Usage:
    # Run against live environment (requires all services running):
    pytest tests/e2e_pipeline_test.py -v

    # Skip if services are unavailable (CI-safe):
    pytest tests/e2e_pipeline_test.py -v -m e2e

Environment Variables:
    DASHBOARD_URL   - Dashboard API base URL (default: http://localhost:3001)
    GENERATOR_URL   - Event generator API base URL (default: http://localhost:8000)
    SNOWFLAKE_ACCOUNT    - Snowflake account identifier
    SNOWFLAKE_USER       - Snowflake user
    SNOWFLAKE_PASSWORD   - Snowflake password (or use key pair below)
    SNOWFLAKE_PRIVATE_KEY_PATH - Path to private key file (alternative to password)
    SNOWFLAKE_DATABASE   - Snowflake database (default: PAYMENTS_DB)
    SNOWFLAKE_WAREHOUSE  - Snowflake warehouse for checks (default: PAYMENTS_ADMIN_WH)
"""

import os
import time
import pytest
import requests
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DASHBOARD_URL = os.getenv("DASHBOARD_URL", "http://localhost:3001").rstrip("/")
GENERATOR_URL = os.getenv("GENERATOR_URL", "http://localhost:8000").rstrip("/")
SNOWFLAKE_DATABASE = os.getenv("SNOWFLAKE_DATABASE", "PAYMENTS_DB")
SNOWFLAKE_WAREHOUSE = os.getenv("SNOWFLAKE_WAREHOUSE", "PAYMENTS_ADMIN_WH")

# Timing constants (seconds)
SCENARIO_PROPAGATION_WAIT = 90      # Time for interactive table to refresh after scenario inject
RECOVERY_WAIT = 120                  # Time for metrics to return to baseline after scenario clear
INGEST_LAG_THRESHOLD = 30           # Max acceptable ingest lag (seconds)
INTERACTIVE_TABLE_LAG_THRESHOLD = 90  # Max acceptable serving lag (seconds)


# ---------------------------------------------------------------------------
# Fixtures / helpers
# ---------------------------------------------------------------------------

def _get(path: str, base: str = DASHBOARD_URL, **params) -> requests.Response:
    """GET request against dashboard API with query params."""
    return requests.get(f"{base}{path}", params=params, timeout=10)


def _generator_get(path: str) -> requests.Response:
    """GET request against generator API."""
    return requests.get(f"{GENERATOR_URL}{path}", timeout=5)


def _generator_post(path: str, json_body: dict) -> requests.Response:
    """POST request against generator API."""
    return requests.post(f"{GENERATOR_URL}{path}", json=json_body, timeout=5)


def _generator_delete(path: str) -> requests.Response:
    """DELETE request against generator API."""
    return requests.delete(f"{GENERATOR_URL}{path}", timeout=5)


def _snowflake_connection():
    """Return a live Snowflake connection or None if credentials are not configured."""
    try:
        import snowflake.connector  # type: ignore

        account = os.getenv("SNOWFLAKE_ACCOUNT")
        user = os.getenv("SNOWFLAKE_USER")
        if not account or not user:
            return None

        connect_kwargs: dict = {
            "account": account,
            "user": user,
            "database": SNOWFLAKE_DATABASE,
            "warehouse": SNOWFLAKE_WAREHOUSE,
        }

        private_key_path = os.getenv("SNOWFLAKE_PRIVATE_KEY_PATH")
        if private_key_path:
            from cryptography.hazmat.backends import default_backend  # type: ignore
            from cryptography.hazmat.primitives.serialization import (  # type: ignore
                Encoding,
                NoEncryption,
                PrivateFormat,
                load_pem_private_key,
            )

            with open(private_key_path, "rb") as key_file:
                p_key = load_pem_private_key(
                    key_file.read(),
                    password=os.getenv("SNOWFLAKE_PRIVATE_KEY_PASSPHRASE", "").encode() or None,
                    backend=default_backend(),
                )
            connect_kwargs["private_key"] = p_key.private_bytes(
                Encoding.DER, PrivateFormat.PKCS8, NoEncryption()
            )
        else:
            password = os.getenv("SNOWFLAKE_PASSWORD")
            if not password:
                return None
            connect_kwargs["password"] = password

        return snowflake.connector.connect(**connect_kwargs)
    except Exception:
        return None


def _skip_if_generator_down():
    """Return True if generator is not reachable or not returning valid status JSON."""
    try:
        r = _generator_get("/status")
        if r.status_code != 200:
            return True
        data = r.json()
        # Must have events_per_sec to be a real generator response
        return "events_per_sec" not in data
    except (requests.RequestException, requests.exceptions.JSONDecodeError, ValueError):
        return True


def _skip_if_dashboard_down():
    """Return True if dashboard API is not reachable."""
    try:
        r = _get("/health")
        return r.status_code != 200
    except requests.RequestException:
        return True


def _skip_if_snowflake_unavailable():
    """Return True if Snowflake connection cannot be established."""
    conn = _snowflake_connection()
    if conn is None:
        return True
    try:
        conn.close()
        return False
    except Exception:
        return True


# ---------------------------------------------------------------------------
# Test Suite
# ---------------------------------------------------------------------------


@pytest.mark.e2e
class TestE2EPipeline:
    """Full pipeline integration tests. Requires all services running."""

    # ------------------------------------------------------------------
    # Test 1 — Generator health
    # ------------------------------------------------------------------

    def test_generator_produces_events(self):
        """Verify event generator is running and actively producing to Kafka topic."""
        if _skip_if_generator_down():
            pytest.skip("Event generator not reachable at GENERATOR_URL")

        start = time.time()
        r = _generator_get("/status")
        elapsed = time.time() - start

        assert r.status_code == 200, f"Generator /status returned {r.status_code}"

        status = r.json()
        print(f"\n  Generator status ({elapsed:.2f}s): {status}")

        assert "events_per_sec" in status, "Missing events_per_sec in generator status"
        assert status["events_per_sec"] > 0, (
            f"Generator events_per_sec={status['events_per_sec']}, expected >0. "
            "Is the producer loop running?"
        )
        print(f"  ✓ Generator producing {status['events_per_sec']} events/sec")

    # ------------------------------------------------------------------
    # Test 2 — Snowflake ingest
    # ------------------------------------------------------------------

    def test_snowflake_ingest_active(self):
        """Verify events landing in RAW.AUTH_EVENTS_RAW within INGEST_LAG_THRESHOLD seconds."""
        conn = _snowflake_connection()
        if conn is None:
            pytest.skip("Snowflake credentials not configured — set SNOWFLAKE_ACCOUNT/USER/PASSWORD")

        start = time.time()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    f"""
                    SELECT
                        COUNT(*) AS event_count,
                        MAX(ingested_at) AS latest_ingest,
                        DATEDIFF('second', MAX(ingested_at), CURRENT_TIMESTAMP()) AS lag_sec
                    FROM {SNOWFLAKE_DATABASE}.RAW.AUTH_EVENTS_RAW
                    WHERE ingested_at >= DATEADD('MINUTE', -5, CURRENT_TIMESTAMP())
                    """
                )
                row = cur.fetchone()
        finally:
            conn.close()

        elapsed = time.time() - start
        event_count, latest_ingest, lag_sec = row
        print(
            f"\n  Ingest check ({elapsed:.2f}s): "
            f"count={event_count}, latest={latest_ingest}, lag={lag_sec}s"
        )

        assert event_count is not None and event_count > 0, (
            f"No events ingested in last 5 minutes. "
            f"Check generator and Kafka connector are running."
        )
        assert lag_sec is not None and lag_sec <= INGEST_LAG_THRESHOLD, (
            f"Ingest lag {lag_sec}s exceeds threshold {INGEST_LAG_THRESHOLD}s. "
            f"Check Snowpipe Streaming HP connector."
        )
        print(
            f"  ✓ {event_count} events in last 5min, lag={lag_sec}s "
            f"(threshold={INGEST_LAG_THRESHOLD}s)"
        )

    # ------------------------------------------------------------------
    # Test 3 — Interactive table refresh
    # ------------------------------------------------------------------

    def test_interactive_table_refresh(self):
        """Verify IT_AUTH_MINUTE_METRICS is refreshing on expected 60s cadence."""
        conn = _snowflake_connection()
        if conn is None:
            pytest.skip("Snowflake credentials not configured")

        start = time.time()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    f"""
                    SELECT
                        name,
                        state,
                        refresh_start_time,
                        refresh_end_time,
                        DATEDIFF('second', refresh_end_time, CURRENT_TIMESTAMP()) AS seconds_since_refresh,
                        error_message
                    FROM TABLE(
                        {SNOWFLAKE_DATABASE}.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY()
                    )
                    WHERE name = 'IT_AUTH_MINUTE_METRICS'
                    ORDER BY refresh_start_time DESC
                    LIMIT 1
                    """
                )
                row = cur.fetchone()
        finally:
            conn.close()

        elapsed = time.time() - start

        assert row is not None, (
            "No refresh history found for IT_AUTH_MINUTE_METRICS. "
            "Verify the interactive table exists in PAYMENTS_DB.SERVE."
        )

        name, state, refresh_start, refresh_end, seconds_since, error_msg = row
        print(
            f"\n  IT refresh check ({elapsed:.2f}s): "
            f"state={state}, last_refresh={refresh_end}, age={seconds_since}s"
        )

        assert state == "SUCCEEDED", (
            f"Latest refresh state={state!r} (expected SUCCEEDED). "
            f"Error: {error_msg}"
        )
        assert seconds_since is not None and seconds_since <= INTERACTIVE_TABLE_LAG_THRESHOLD, (
            f"Interactive table last refreshed {seconds_since}s ago "
            f"(threshold={INTERACTIVE_TABLE_LAG_THRESHOLD}s). "
            f"Check PAYMENTS_REFRESH_WH is running."
        )
        print(
            f"  ✓ IT_AUTH_MINUTE_METRICS refreshed {seconds_since}s ago "
            f"(threshold={INTERACTIVE_TABLE_LAG_THRESHOLD}s)"
        )

    # ------------------------------------------------------------------
    # Test 4 — Scenario injection end-to-end
    # ------------------------------------------------------------------

    def test_scenario_injection_end_to_end(self):
        """
        Full pipeline test: inject issuer_outage → wait → validate dashboard response
        shows increased decline rate → clear scenario → validate recovery.

        This test takes ~90 seconds due to interactive table refresh cadence.
        """
        if _skip_if_generator_down():
            pytest.skip("Event generator not reachable at GENERATOR_URL")
        if _skip_if_dashboard_down():
            pytest.skip("Dashboard API not reachable at DASHBOARD_URL")

        # --- Baseline ---
        print("\n  [1/5] Capturing baseline metrics...")
        r = _get("/api/v1/summary", time_range=15)
        assert r.status_code == 200, f"Baseline summary failed: {r.status_code}"
        baseline = r.json()
        baseline_decline = baseline.get("current_decline_rate") or 0.0
        print(f"  Baseline decline rate: {baseline_decline:.1f}%")

        # --- Inject scenario ---
        print("  [2/5] Injecting issuer_outage scenario...")
        r = _generator_post("/scenario", {"profile": "issuer_outage", "duration_sec": 300})
        assert r.status_code in (200, 201), f"Scenario inject failed: {r.status_code} {r.text}"

        # --- Wait for propagation ---
        print(f"  [3/5] Waiting {SCENARIO_PROPAGATION_WAIT}s for interactive table refresh...")
        time.sleep(SCENARIO_PROPAGATION_WAIT)

        # --- Validate scenario effects ---
        print("  [4/5] Validating scenario effects on dashboard...")

        summary_r = _get("/api/v1/summary", time_range=15)
        assert summary_r.status_code == 200, f"Summary call failed: {summary_r.status_code}"
        scenario_summary = summary_r.json()
        scenario_decline = scenario_summary.get("current_decline_rate") or 0.0

        breakdown_r = _get("/api/v1/breakdown", dimension="issuer_bin", time_range=15)
        assert breakdown_r.status_code == 200, f"Breakdown call failed: {breakdown_r.status_code}"
        breakdown_data = breakdown_r.json()

        events_r = _get("/api/v1/events", auth_status="DECLINED", time_range=15)
        assert events_r.status_code == 200, f"Events call failed: {events_r.status_code}"
        events_data = events_r.json()

        print(f"  Scenario decline rate: {scenario_decline:.1f}% (baseline: {baseline_decline:.1f}%)")
        print(f"  Breakdown rows: {len(breakdown_data.get('rows', []))}")
        print(f"  Recent declined events: {events_data.get('total_count', 0)}")

        assert scenario_decline > baseline_decline, (
            f"Decline rate did not increase after issuer_outage injection. "
            f"Baseline={baseline_decline:.1f}%, After={scenario_decline:.1f}%. "
            f"Check interactive table refresh has completed."
        )

        # Verify ISSUER_UNAVAILABLE codes in recent failures
        declined_events = events_data.get("events", [])
        issuer_codes = [
            e.get("decline_code") for e in declined_events
            if e.get("decline_code") == "ISSUER_UNAVAILABLE"
        ]
        assert len(issuer_codes) > 0, (
            "No ISSUER_UNAVAILABLE decline codes found in recent failures. "
            f"Found codes: {set(e.get('decline_code') for e in declined_events)}"
        )
        print(f"  ✓ Decline rate increased: {baseline_decline:.1f}% → {scenario_decline:.1f}%")
        print(f"  ✓ {len(issuer_codes)} ISSUER_UNAVAILABLE events in recent failures")

        # --- Recovery ---
        print("  [5/5] Clearing scenario and validating recovery...")
        r = _generator_delete("/scenario")
        assert r.status_code in (200, 204), f"Scenario clear failed: {r.status_code}"

        # Wait for recovery (one full IT refresh cycle)
        print(f"  Waiting {SCENARIO_PROPAGATION_WAIT}s for recovery refresh...")
        time.sleep(SCENARIO_PROPAGATION_WAIT)

        recovery_r = _get("/api/v1/summary", time_range=15)
        assert recovery_r.status_code == 200
        recovery = recovery_r.json()
        recovery_decline = recovery.get("current_decline_rate") or 0.0
        print(f"  Recovery decline rate: {recovery_decline:.1f}%")

        assert recovery_decline < scenario_decline, (
            f"Metrics did not recover after scenario clear. "
            f"Peak={scenario_decline:.1f}%, Recovery={recovery_decline:.1f}%"
        )
        print(
            f"  ✓ Recovery confirmed: {scenario_decline:.1f}% → {recovery_decline:.1f}%"
        )

    # ------------------------------------------------------------------
    # Test 5 — Dashboard API smoke test
    # ------------------------------------------------------------------

    def test_dashboard_api_all_endpoints(self):
        """Smoke test all 6 API endpoints return 200 and valid JSON."""
        if _skip_if_dashboard_down():
            pytest.skip("Dashboard API not reachable at DASHBOARD_URL")

        endpoints = [
            ("/health", {}),
            ("/api/v1/summary", {"time_range": 15}),
            ("/api/v1/timeseries", {"time_range": 15}),
            ("/api/v1/breakdown", {"dimension": "region", "time_range": 15}),
            ("/api/v1/events", {"time_range": 15}),
            ("/api/v1/latency", {"time_range": 15}),
            ("/api/v1/filters", {}),
        ]

        print("\n  Dashboard API smoke test:")
        for path, params in endpoints:
            start = time.time()
            r = _get(path, **params)
            elapsed = time.time() - start

            assert r.status_code == 200, (
                f"GET {path} returned {r.status_code}: {r.text[:200]}"
            )
            # Validate JSON parseable
            payload = r.json()
            assert payload is not None, f"GET {path} returned null JSON"

            print(f"  ✓ GET {path} → 200 ({elapsed:.2f}s)")

        print(f"  ✓ All {len(endpoints)} endpoints healthy")
