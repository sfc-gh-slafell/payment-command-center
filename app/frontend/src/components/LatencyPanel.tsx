import { BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer } from 'recharts';
import type { DashboardFilters, LatencyResponse } from '../types/api';
import { useApiQuery } from '../hooks/useApiQuery';

interface Props {
  filters: DashboardFilters;
}

export default function LatencyPanel({ filters }: Props) {
  const { data } = useApiQuery<LatencyResponse>('latency', '/api/v1/latency', filters);

  const histogram = data?.histogram ?? [];
  const stats = data?.statistics;

  return (
    <div className="bg-dashboard-card border border-dashboard-border rounded-lg p-4">
      <h3 className="text-sm font-medium text-dashboard-muted mb-3">Latency Distribution</h3>

      {/* Histogram bar chart */}
      {histogram.length > 0 ? (
        <ResponsiveContainer width="100%" height={180}>
          <BarChart data={histogram}>
            <XAxis dataKey="label" tick={{ fontSize: 10, fill: '#94a3b8' }} />
            <YAxis tick={{ fontSize: 10, fill: '#94a3b8' }} />
            <Tooltip contentStyle={{ backgroundColor: '#1e293b', border: '1px solid #334155' }} />
            <Bar dataKey="count" fill="#8b5cf6" name="Events" />
          </BarChart>
        </ResponsiveContainer>
      ) : (
        <div className="h-[180px] flex items-center justify-center text-dashboard-muted text-sm">
          No latency data
        </div>
      )}

      {/* Percentile stats */}
      {stats && (
        <div className="grid grid-cols-3 gap-2 mt-3 text-center text-sm">
          <div>
            <div className="text-dashboard-muted text-xs">p50</div>
            <div className="font-mono">{stats.p50?.toFixed(0) ?? '--'}ms</div>
          </div>
          <div>
            <div className="text-dashboard-muted text-xs">p95</div>
            <div className="font-mono">{stats.p95?.toFixed(0) ?? '--'}ms</div>
          </div>
          <div>
            <div className="text-dashboard-muted text-xs">p99</div>
            <div className="font-mono">{stats.p99?.toFixed(0) ?? '--'}ms</div>
          </div>
          <div>
            <div className="text-dashboard-muted text-xs">avg</div>
            <div className="font-mono">{stats.avg?.toFixed(0) ?? '--'}ms</div>
          </div>
          <div>
            <div className="text-dashboard-muted text-xs">min</div>
            <div className="font-mono">{stats.min?.toFixed(0) ?? '--'}ms</div>
          </div>
          <div>
            <div className="text-dashboard-muted text-xs">max</div>
            <div className="font-mono">{stats.max?.toFixed(0) ?? '--'}ms</div>
          </div>
        </div>
      )}
    </div>
  );
}
