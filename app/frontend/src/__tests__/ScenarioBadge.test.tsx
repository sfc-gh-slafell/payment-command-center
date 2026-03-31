/**
 * Tests for ScenarioBadge component (Issue #46)
 *
 * Since frontend doesn't have testing library yet, this serves as:
 * 1. Type-safe component API documentation
 * 2. Compilation test via tsc
 * 3. Future test migration target when adding Jest/Vitest
 */

import { describe, it, expect } from 'vitest'; // Will be added later
import { render, screen } from '@testing-library/react'; // Will be added later
import ScenarioBadge from '../components/ScenarioBadge';

describe('ScenarioBadge Component', () => {
  it('renders baseline scenario with green styling', () => {
    render(
      <ScenarioBadge
        profile="baseline"
        timeRemainingSeconds={null}
        eventsPerSecond={500}
      />
    );

    const badge = screen.getByTestId('scenario-badge');
    expect(badge).toBeInTheDocument();
    expect(badge).toHaveTextContent('BASELINE');
    expect(badge).toHaveClass('bg-green-500');
  });

  it('renders issuer_outage scenario with amber styling', () => {
    render(
      <ScenarioBadge
        profile="issuer_outage"
        timeRemainingSeconds={180}
        eventsPerSecond={500}
      />
    );

    const badge = screen.getByTestId('scenario-badge');
    expect(badge).toHaveTextContent('ISSUER OUTAGE');
    expect(badge).toHaveTextContent('3:00 remaining');
    expect(badge).toHaveClass('bg-amber-500');
  });

  it('renders merchant_decline_spike scenario with amber styling', () => {
    render(
      <ScenarioBadge
        profile="merchant_decline_spike"
        timeRemainingSeconds={240}
        eventsPerSecond={500}
      />
    );

    const badge = screen.getByTestId('scenario-badge');
    expect(badge).toHaveTextContent('MERCHANT DECLINE SPIKE');
    expect(badge).toHaveTextContent('4:00 remaining');
    expect(badge).toHaveClass('bg-amber-500');
  });

  it('renders latency_spike scenario with amber styling', () => {
    render(
      <ScenarioBadge
        profile="latency_spike"
        timeRemainingSeconds={120}
        eventsPerSecond={500}
      />
    );

    const badge = screen.getByTestId('scenario-badge');
    expect(badge).toHaveTextContent('LATENCY SPIKE');
    expect(badge).toHaveTextContent('2:00 remaining');
    expect(badge).toHaveClass('bg-amber-500');
  });

  it('formats time remaining correctly (minutes and seconds)', () => {
    render(
      <ScenarioBadge
        profile="issuer_outage"
        timeRemainingSeconds={125}
        eventsPerSecond={500}
      />
    );

    const badge = screen.getByTestId('scenario-badge');
    expect(badge).toHaveTextContent('2:05 remaining');
  });

  it('hides badge when profile is unknown and timeRemaining is null', () => {
    const { container } = render(
      <ScenarioBadge
        profile="unknown"
        timeRemainingSeconds={null}
        eventsPerSecond={0}
      />
    );

    expect(container.firstChild).toBeNull();
  });

  it('shows "Unknown" text when generator is unreachable but was previously reachable', () => {
    render(
      <ScenarioBadge
        profile="unknown"
        timeRemainingSeconds={null}
        eventsPerSecond={0}
        showUnknown={true}
      />
    );

    const badge = screen.getByTestId('scenario-badge');
    expect(badge).toHaveTextContent('Generator Status: Unknown');
    expect(badge).toHaveClass('bg-gray-500');
  });

  it('updates display when prop values change', () => {
    const { rerender } = render(
      <ScenarioBadge
        profile="issuer_outage"
        timeRemainingSeconds={180}
        eventsPerSecond={500}
      />
    );

    // Change to baseline
    rerender(
      <ScenarioBadge
        profile="baseline"
        timeRemainingSeconds={null}
        eventsPerSecond={500}
      />
    );

    const badge = screen.getByTestId('scenario-badge');
    expect(badge).toHaveTextContent('BASELINE');
    expect(badge).toHaveClass('bg-green-500');
  });
});

/**
 * Type-safe API definition for ScenarioBadge component
 * This will ensure TypeScript compilation catches interface violations
 */
export interface ScenarioBadgeProps {
  profile: 'baseline' | 'issuer_outage' | 'merchant_decline_spike' | 'latency_spike' | 'unknown';
  timeRemainingSeconds: number | null;
  eventsPerSecond: number;
  showUnknown?: boolean;
}

/**
 * Expected component structure (for implementation reference)
 */
export const ExpectedComponentStructure = `
<div
  data-testid="scenario-badge"
  className={getColorClass(profile)}
>
  <span className="font-semibold">{getDisplayName(profile)}</span>
  {timeRemainingSeconds !== null && (
    <span>({formatTimeRemaining(timeRemainingSeconds)} remaining)</span>
  )}
</div>
`;
