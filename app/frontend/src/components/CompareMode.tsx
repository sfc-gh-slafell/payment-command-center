import type { DashboardFilters, SummaryResponse } from '../types/api';
import { useApiQuery } from '../hooks/useApiQuery';

interface Props {
  filters: DashboardFilters;
}

function DeltaRow({ label, current, prev, unit, invertColor }: {
  label: string;
  current: number | null;
  prev: number | null;
  unit: string;
  invertColor?: boolean;
}) {
  const delta = current != null && prev != null ? current - prev : null;
  let deltaColor = 'text-dashboard-muted';
  if (delta != null && Math.abs(delta) > 0.01) {
    const isPositive = delta > 0;
    const isGood = invertColor ? !isPositive : isPositive;
    deltaColor = isGood ? 'text-dashboard-success' : 'text-dashboard-danger';
  }

  return (
    <div className="flex justify-between py-1 border-b border-dashboard-border/30">
      <span className="text-dashboard-muted text-sm">{label}</span>
      <div className="text-right">
        <span className="font-mono">{current?.toFixed(1) ?? '--'}{unit}</span>
        <span className="text-xs ml-2">vs</span>
        <span className="font-mono text-sm ml-2">{prev?.toFixed(1) ?? '--'}{unit}</span>
        {delta != null && (
          <span className={`ml-2 text-xs ${deltaColor}`}>
            ({delta > 0 ? '+' : ''}{delta.toFixed(1)})
          </span>
        )}
      </div>
    </div>
  );
}

export default function CompareMode({ filters }: Props) {
  const { data: current } = useApiQuery<SummaryResponse>('summary-current', '/api/v1/summary', filters);
  const prevFilters = { ...filters, time_range: filters.time_range * 2 };
  const { data: prev } = useApiQuery<SummaryResponse>('summary-prev', '/api/v1/summary', prevFilters);

  return (
    <div className="bg-dashboard-card border border-dashboard-border rounded-lg p-4">
      <h3 className="text-sm font-medium text-dashboard-muted mb-3">
        Compare: Current {filters.time_range}m vs Previous {filters.time_range}m
      </h3>
      <DeltaRow label="Approval Rate" current={current?.current_approval_rate ?? null} prev={prev?.prev_approval_rate ?? null} unit="%" />
      <DeltaRow label="Decline Rate" current={current?.current_decline_rate ?? null} prev={prev?.prev_decline_rate ?? null} unit="%" invertColor />
      <DeltaRow label="Avg Latency" current={current?.current_avg_latency_ms ?? null} prev={prev?.prev_avg_latency_ms ?? null} unit="ms" invertColor />
      <DeltaRow label="Event Volume" current={current?.current_events ?? null} prev={prev?.prev_events ?? null} unit="" />
    </div>
  );
}
