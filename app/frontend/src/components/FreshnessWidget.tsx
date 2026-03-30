import { formatDistanceToNowStrict } from 'date-fns';
import type { DashboardFilters, SummaryResponse } from '../types/api';
import { useApiQuery } from '../hooks/useApiQuery';

interface Props {
  filters: DashboardFilters;
}

function ageColor(ageMs: number): string {
  if (ageMs < 30_000) return 'text-dashboard-success';    // green <30s
  if (ageMs < 120_000) return 'text-dashboard-warning';   // yellow 30-120s
  return 'text-dashboard-danger';                          // red >120s (stale)
}

function formatAge(ts: string | null): { text: string; colorClass: string } {
  if (!ts) return { text: '--', colorClass: 'text-dashboard-muted' };
  try {
    const date = new Date(ts);
    const ageMs = Date.now() - date.getTime();
    return {
      text: formatDistanceToNowStrict(date, { addSuffix: true }),
      colorClass: ageColor(ageMs),
    };
  } catch {
    return { text: ts, colorClass: 'text-dashboard-muted' };
  }
}

export default function FreshnessWidget({ filters }: Props) {
  const { data } = useApiQuery<SummaryResponse>('summary-freshness', '/api/v1/summary', filters);

  const raw = formatAge(data?.freshness?.last_raw_ts ?? null);
  const serving = formatAge(data?.freshness?.last_serve_ts ?? null);

  return (
    <div className="bg-dashboard-card border border-dashboard-border rounded-lg p-4">
      <h3 className="text-sm font-medium text-dashboard-muted mb-3">Data Freshness</h3>
      <div className="space-y-2">
        <div className="flex justify-between items-center">
          <span className="text-sm text-dashboard-muted">Raw</span>
          <span className={`font-mono text-sm ${raw.colorClass}`}>{raw.text}</span>
        </div>
        <div className="flex justify-between items-center">
          <span className="text-sm text-dashboard-muted">Serving</span>
          <span className={`font-mono text-sm ${serving.colorClass}`}>{serving.text}</span>
        </div>
      </div>
      <p className="text-xs text-dashboard-muted mt-3">
        Raw arrives in seconds via HP connector. Serving refreshes every 60s via interactive tables.
      </p>
    </div>
  );
}
