"""Tests for scenario indicator backend implementation (Issue #46)."""

import pytest
from unittest.mock import Mock, patch, MagicMock
from datetime import datetime, timedelta


class TestScenarioIndicatorBackend:
    """Test suite for scenario indicator backend changes."""

    def test_summary_response_includes_scenario_field(self):
        """Test that SummaryResponse model includes scenario field."""
        from app.backend.routes.summary import SummaryResponse

        # Create a response with scenario data
        response = SummaryResponse(
            current_events=1000,
            current_approval_rate=95.0,
            scenario={
                "profile": "issuer_outage",
                "time_remaining_sec": 180,
                "events_per_sec": 500
            }
        )

        assert hasattr(response, 'scenario')
        assert response.scenario['profile'] == 'issuer_outage'
        assert response.scenario['time_remaining_sec'] == 180
        assert response.scenario['events_per_sec'] == 500

    def test_generator_client_polls_status_endpoint(self):
        """Test that backend has a client to poll generator /status endpoint."""
        # This will fail until we implement the generator client
        from app.backend.generator_client import GeneratorClient

        client = GeneratorClient(base_url="http://localhost:8000")

        # Mock the HTTP call
        with patch('requests.get') as mock_get:
            mock_get.return_value.json.return_value = {
                "scenario": "baseline",
                "events_per_sec": 500,
                "env": "dev",
                "total_events": 10000,
                "uptime_sec": 300
            }

            status = client.get_status()

            assert status['scenario'] == 'baseline'
            assert status['events_per_sec'] == 500
            mock_get.assert_called_once_with(
                "http://localhost:8000/status",
                timeout=2
            )

    def test_generator_client_caches_status_for_5_seconds(self):
        """Test that generator status is cached for 5 seconds."""
        from app.backend.generator_client import GeneratorClient

        client = GeneratorClient(base_url="http://localhost:8000", cache_ttl=5)

        with patch('requests.get') as mock_get:
            mock_get.return_value.json.return_value = {
                "scenario": "baseline",
                "events_per_sec": 500,
                "env": "dev",
                "total_events": 10000,
                "uptime_sec": 300
            }

            # First call
            status1 = client.get_status()
            # Second call immediately after (should use cache)
            status2 = client.get_status()

            # Should only call the API once due to caching
            assert mock_get.call_count == 1
            assert status1 == status2

    def test_generator_client_refreshes_cache_after_expiry(self):
        """Test that cache refreshes after TTL expires."""
        from app.backend.generator_client import GeneratorClient

        client = GeneratorClient(base_url="http://localhost:8000", cache_ttl=0.1)

        with patch('requests.get') as mock_get:
            mock_get.return_value.json.return_value = {
                "scenario": "baseline",
                "events_per_sec": 500
            }

            # First call
            client.get_status()

            # Wait for cache expiry
            import time
            time.sleep(0.2)

            # Second call after expiry
            client.get_status()

            # Should call API twice
            assert mock_get.call_count == 2

    def test_generator_client_handles_connection_error_gracefully(self):
        """Test that generator client returns fallback data when unreachable."""
        from app.backend.generator_client import GeneratorClient
        import requests

        client = GeneratorClient(base_url="http://localhost:8000")

        with patch('requests.get') as mock_get:
            mock_get.side_effect = requests.ConnectionError("Connection refused")

            status = client.get_status()

            # Should return fallback data
            assert status['profile'] == 'unknown'
            assert status['time_remaining_sec'] is None
            assert status['events_per_sec'] == 0

    def test_summary_endpoint_includes_scenario_from_generator(self):
        """Test that /api/v1/summary endpoint includes scenario data."""
        # This will fail until we modify the summary route
        from fastapi.testclient import TestClient
        from app.backend.main import app

        # Mock the Snowflake client and generator client
        with patch('app.backend.main.get_client') as mock_get_client, \
             patch('app.backend.routes.summary.get_generator_status') as mock_gen:

            mock_client = Mock()
            mock_client.execute_query.return_value = [
                {
                    "CURRENT_EVENTS": 1000,
                    "CURRENT_APPROVAL_RATE": 95.0,
                    "CURRENT_DECLINE_RATE": 5.0,
                    "CURRENT_AVG_LATENCY_MS": 100.0,
                    "PREV_EVENTS": 950,
                    "PREV_APPROVAL_RATE": 96.0,
                    "PREV_DECLINE_RATE": 4.0,
                    "PREV_AVG_LATENCY_MS": 98.0,
                    "LAST_SERVE_TS": datetime.now()
                }
            ]
            mock_get_client.return_value = mock_client

            mock_gen.return_value = {
                "profile": "issuer_outage",
                "time_remaining_sec": 240,
                "events_per_sec": 500
            }

            client = TestClient(app)
            response = client.get("/api/v1/summary")

            assert response.status_code == 200
            data = response.json()
            assert 'scenario' in data
            assert data['scenario']['profile'] == 'issuer_outage'
            assert data['scenario']['time_remaining_sec'] == 240

    def test_scenario_time_remaining_calculation(self):
        """Test time remaining calculation from generator response."""
        from app.backend.generator_client import calculate_time_remaining

        # Generator returns uptime and duration for scenarios
        # We need to calculate time_remaining = duration - (current_time - scenario_start_time)

        # Scenario started 60 seconds ago, duration is 300 seconds
        scenario_start = datetime.now() - timedelta(seconds=60)
        duration_sec = 300

        remaining = calculate_time_remaining(scenario_start, duration_sec)

        assert 235 <= remaining <= 245  # Allow some timing variance

    def test_backend_env_var_for_generator_url(self):
        """Test that GENERATOR_URL environment variable is used."""
        import os
        from app.backend.generator_client import GeneratorClient

        # Set environment variable
        os.environ['GENERATOR_URL'] = 'http://custom-generator:8080'

        client = GeneratorClient.from_env()

        assert client.base_url == 'http://custom-generator:8080'

        # Cleanup
        del os.environ['GENERATOR_URL']


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
