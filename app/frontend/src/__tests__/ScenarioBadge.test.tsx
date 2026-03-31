/**
 * Type-safe interface documentation for ScenarioBadge component (Issue #46)
 *
 * This file serves as:
 * 1. Type-safe component API documentation
 * 2. Compilation test via tsc
 * 3. Future test migration target when adding vitest + @testing-library/react
 *
 * Each JSX expression below verifies the component accepts the correct
 * scenario: ScenarioInfo prop shape and compiles without errors.
 */

import ScenarioBadge from '../components/ScenarioBadge';
import type { ScenarioInfo } from '../types/api';

// Baseline scenario — no time countdown, green styling
const _baseline = (
  <ScenarioBadge
    scenario={{ profile: 'baseline', time_remaining_sec: null, events_per_sec: 500 }}
  />
);

// Issuer outage — amber styling with 3:00 countdown
const _issuerOutage = (
  <ScenarioBadge
    scenario={{ profile: 'issuer_outage', time_remaining_sec: 180, events_per_sec: 500 }}
  />
);

// Merchant decline spike — amber styling with 4:00 countdown
const _merchantDecline = (
  <ScenarioBadge
    scenario={{ profile: 'merchant_decline_spike', time_remaining_sec: 240, events_per_sec: 500 }}
  />
);

// Latency spike — amber styling with 2:00 countdown
const _latencySpike = (
  <ScenarioBadge
    scenario={{ profile: 'latency_spike', time_remaining_sec: 120, events_per_sec: 500 }}
  />
);

// Unknown / generator unreachable — hidden (returns null)
const _unknown = (
  <ScenarioBadge
    scenario={{ profile: 'unknown', time_remaining_sec: null, events_per_sec: 0 }}
  />
);

// Verify ScenarioInfo type shape compiles correctly
const _typeCheck: ScenarioInfo = {
  profile: 'baseline',
  time_remaining_sec: null,
  events_per_sec: 0,
};

// Suppress unused variable warnings
void _baseline;
void _issuerOutage;
void _merchantDecline;
void _latencySpike;
void _unknown;
void _typeCheck;
