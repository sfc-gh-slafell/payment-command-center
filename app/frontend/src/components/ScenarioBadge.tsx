import type { ScenarioInfo } from '../types/api';

interface ScenarioBadgeProps {
  scenario: ScenarioInfo;
}

function getScenarioDisplayName(profile: string): string {
  const names: Record<string, string> = {
    baseline: 'BASELINE',
    issuer_outage: 'ISSUER OUTAGE',
    merchant_decline_spike: 'MERCHANT DECLINE SPIKE',
    latency_spike: 'LATENCY SPIKE',
    unknown: 'Generator Status: Unknown',
  };
  return names[profile] || profile.toUpperCase();
}

function getScenarioColorClass(profile: string): string {
  if (profile === 'baseline') {
    return 'bg-green-600 text-white';
  }
  if (profile === 'unknown') {
    return 'bg-gray-500 text-white';
  }
  // issuer_outage, merchant_decline_spike, latency_spike
  return 'bg-amber-500 text-white';
}

function formatTimeRemaining(seconds: number): string {
  const mins = Math.floor(seconds / 60);
  const secs = seconds % 60;
  return `${mins}:${secs.toString().padStart(2, '0')}`;
}

export default function ScenarioBadge({ scenario }: ScenarioBadgeProps) {
  // Hide badge if unknown and no recent data
  if (scenario.profile === 'unknown' && scenario.time_remaining_sec === null) {
    return null;
  }

  const displayName = getScenarioDisplayName(scenario.profile);
  const colorClass = getScenarioColorClass(scenario.profile);

  return (
    <div
      data-testid="scenario-badge"
      className={`px-4 py-2 ${colorClass} text-sm font-medium tracking-wide shadow-sm`}
    >
      <div className="flex items-center justify-between max-w-7xl mx-auto">
        <div className="flex items-center gap-2">
          <span className="inline-block w-2 h-2 rounded-full bg-white animate-pulse" />
          <span className="font-semibold">{displayName}</span>
        </div>
        {scenario.time_remaining_sec !== null && scenario.time_remaining_sec > 0 && (
          <span className="text-sm opacity-90">
            ({formatTimeRemaining(scenario.time_remaining_sec)} remaining)
          </span>
        )}
        {scenario.events_per_sec > 0 && (
          <span className="text-xs opacity-75">
            {scenario.events_per_sec} events/sec
          </span>
        )}
      </div>
    </div>
  );
}
