import type { DashboardFilters, SummaryResponse } from '../types/api';
import { useApiQuery } from '../hooks/useApiQuery';

interface Props {
  filters: DashboardFilters;
}

function formatDelta(current: number | null, prev: number | null): { text: string; color: string } {
  if (current == null || prev == null) return { text: '--', color: 'text-dashboard-muted' };
  const delta = current - prev;
  if (Math.abs(delta) < 0.01) return { text: '0', color: 'text-dashboard-muted' };
  return {
    text: `${delta > 0 ? '+' : ''}${delta.toFixed(1)}`,
    color: delta > 0 ? 'text-dashboard-success' : 'text-dashboard-danger',
  };
}

function KPICard({ label, value, unit, delta }: {
  label: string;
  value: string;
  unit: string;
  delta: { text: string; color: string };
}) {
  return (
    <div className="bg-dashboard-card border border-dashboard-border rounded-lg p-4 flex-1 min-w-[180px]">
      <div className="text-sm text-dashboard-muted mb-1">{label}</div>
      <div className="text-2xl font-semibold">
        {value}<span className="text-sm text-dashboard-muted ml-1">{unit}</span>
      </div>
      <div className={`text-sm mt-1 ${delta.color}`}>
        {delta.text} vs prev
      </div>
    </div>
  );
}

export default function KPIStrip({ filters }: Props) {
  const { data } = useApiQuery<SummaryResponse>('summary', '/api/v1/summary', filters);

  const approvalRate = data?.current_approval_rate;
  const declineRate = data?.current_decline_rate;
  const latency = data?.current_avg_latency_ms;
  const events = data?.current_events;

  const approvalDelta = formatDelta(approvalRate ?? null, data?.prev_approval_rate ?? null);
  const declineDelta = formatDelta(declineRate ?? null, data?.prev_decline_rate ?? null);
  const latencyDelta = formatDelta(latency ?? null, data?.prev_avg_latency_ms ?? null);
  const eventsDelta = formatDelta(events ?? null, data?.prev_events ?? null);

  // For decline rate and latency, higher is worse — invert colors
  const declineDeltaAdjusted = {
    ...declineDelta,
    color: declineDelta.color === 'text-dashboard-success' ? 'text-dashboard-danger' : declineDelta.color === 'text-dashboard-danger' ? 'text-dashboard-success' : declineDelta.color,
  };
  const latencyDeltaAdjusted = {
    ...latencyDelta,
    color: latencyDelta.color === 'text-dashboard-success' ? 'text-dashboard-danger' : latencyDelta.color === 'text-dashboard-danger' ? 'text-dashboard-success' : latencyDelta.color,
  };

  return (
    <div className="flex gap-4 flex-wrap">
      <KPICard
        label="Auth Rate"
        value={approvalRate != null ? approvalRate.toFixed(1) : '--'}
        unit="%"
        delta={approvalDelta}
      />
      <KPICard
        label="Decline Rate"
        value={declineRate != null ? declineRate.toFixed(1) : '--'}
        unit="%"
        delta={declineDeltaAdjusted}
      />
      <KPICard
        label="Avg Latency"
        value={latency != null ? latency.toFixed(0) : '--'}
        unit="ms"
        delta={latencyDeltaAdjusted}
      />
      <KPICard
        label="Event Volume"
        value={events != null ? events.toLocaleString() : '--'}
        unit="events"
        delta={eventsDelta}
      />
    </div>
  );
}
