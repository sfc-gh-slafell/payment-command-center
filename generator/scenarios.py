"""Scenario profiles for modifying event distributions during demos."""

import random
from typing import Protocol


class ScenarioProfile(Protocol):
    """Interface for scenario profiles."""

    def modify_event(self, event: dict, rng: random.Random) -> dict: ...


class Baseline:
    """Default scenario: ~95% approval, 50-150ms latency, uniform distribution."""

    name = "baseline"

    def __init__(self, seed: int | None = None):
        self.rng = random.Random(seed) if seed is not None else random.Random()

    def modify_event(self, event: dict, rng: random.Random | None = None) -> dict:
        # No modifications — baseline uses default generate_event distribution
        return event


class IssuerOutage:
    """BIN range 4111xx drops to 10% approval with ISSUER_UNAVAILABLE."""

    name = "issuer_outage"

    def __init__(self, seed: int | None = None):
        self.rng = random.Random(seed) if seed is not None else random.Random()

    def modify_event(self, event: dict, rng: random.Random | None = None) -> dict:
        r = rng or self.rng
        if event.get("issuer_bin", "").startswith("4111"):
            if r.random() > 0.10:
                event["auth_status"] = "DECLINED"
                event["decline_code"] = "ISSUER_UNAVAILABLE"
        return event


class MerchantDeclineSpike:
    """Specific merchant sees 60% decline rate with DO_NOT_HONOR."""

    name = "merchant_decline_spike"
    target_merchant_id = "M0003"  # TechBazaar

    def __init__(self, seed: int | None = None):
        self.rng = random.Random(seed) if seed is not None else random.Random()

    def modify_event(self, event: dict, rng: random.Random | None = None) -> dict:
        r = rng or self.rng
        if event.get("merchant_id") == self.target_merchant_id:
            if r.random() < 0.60:
                event["auth_status"] = "DECLINED"
                event["decline_code"] = "DO_NOT_HONOR"
        return event


class LatencySpike:
    """EU region latency jumps to 800-2000ms, approval rate stays normal."""

    name = "latency_spike"

    def __init__(self, seed: int | None = None):
        self.rng = random.Random(seed) if seed is not None else random.Random()

    def modify_event(self, event: dict, rng: random.Random | None = None) -> dict:
        r = rng or self.rng
        if event.get("region") == "EU":
            event["auth_latency_ms"] = round(r.uniform(800, 2000), 1)
        return event


SCENARIOS: dict[str, type] = {
    "baseline": Baseline,
    "issuer_outage": IssuerOutage,
    "merchant_decline_spike": MerchantDeclineSpike,
    "latency_spike": LatencySpike,
}
