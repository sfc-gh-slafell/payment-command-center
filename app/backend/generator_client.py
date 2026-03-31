"""Client for polling event generator status with caching."""

import os
import time
from typing import Optional
from datetime import datetime

import requests


class GeneratorClient:
    """Client for fetching scenario status from event generator API."""

    def __init__(self, base_url: str, cache_ttl: float = 5.0):
        """
        Initialize generator client with caching.

        Args:
            base_url: Base URL of generator API (e.g., http://localhost:8000)
            cache_ttl: Cache time-to-live in seconds (default: 5s)
        """
        self.base_url = base_url.rstrip("/")
        self.cache_ttl = cache_ttl
        self._cache: Optional[dict] = None
        self._cache_timestamp: float = 0

    @classmethod
    def from_env(cls) -> "GeneratorClient":
        """Create client from GENERATOR_URL environment variable."""
        url = os.getenv("GENERATOR_URL", "http://localhost:8000")
        return cls(base_url=url)

    def get_status(self) -> dict:
        """
        Get current generator status with caching.

        Returns dict with keys:
            - profile: str (scenario name)
            - time_remaining_sec: int | None
            - events_per_sec: int
        """
        # Check cache validity
        now = time.time()
        if self._cache and (now - self._cache_timestamp) < self.cache_ttl:
            return self._cache

        # Fetch fresh data
        try:
            response = requests.get(
                f"{self.base_url}/status",
                timeout=2
            )
            response.raise_for_status()
            data = response.json()

            # Transform generator response to scenario info
            result = {
                "profile": data.get("scenario", "baseline"),
                "time_remaining_sec": self._calculate_time_remaining(data),
                "events_per_sec": data.get("events_per_sec", 0)
            }

            # Update cache
            self._cache = result
            self._cache_timestamp = now

            return result

        except (requests.ConnectionError, requests.Timeout, requests.RequestException):
            # Generator unreachable - return fallback
            return {
                "profile": "unknown",
                "time_remaining_sec": None,
                "events_per_sec": 0
            }

    def _calculate_time_remaining(self, generator_data: dict) -> Optional[int]:
        """
        Calculate time remaining for active scenario.

        Generator doesn't directly expose time_remaining, so we return None
        for now. In future, generator API could be enhanced to track scenario
        start time and duration.
        """
        # TODO: Enhance generator API to expose scenario_start_time and duration
        # For now, return None (baseline scenarios don't have time limits)
        return None


def calculate_time_remaining(
    scenario_start: datetime,
    duration_sec: int
) -> int:
    """
    Calculate seconds remaining in scenario.

    Args:
        scenario_start: When scenario was activated
        duration_sec: Total scenario duration

    Returns:
        Seconds remaining (clamped to 0 if expired)
    """
    elapsed = (datetime.now() - scenario_start).total_seconds()
    remaining = int(duration_sec - elapsed)
    return max(0, remaining)


def get_generator_status() -> dict:
    """
    Convenience function for routes to fetch generator status.

    Returns scenario info dict for inclusion in API responses.
    """
    client = GeneratorClient.from_env()
    return client.get_status()
