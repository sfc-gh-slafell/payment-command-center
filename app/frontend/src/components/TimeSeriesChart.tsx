import {
  ComposedChart, Bar, Line, XAxis, YAxis, Tooltip,
  ResponsiveContainer, CartesianGrid,
} from 'recharts';
import type { DashboardFilters, TimeseriesResponse } from '../types/api';
import { useApiQuery } from '../hooks/useApiQuery';

interface Props {
  filters: DashboardFilters;
}

export default function TimeSeriesChart({ filters }: Props) {
  const timeseriesFilters = { ...filters, time_range: Math.max(filters.time_range, 60) };
  const { data, isLoading } = useApiQuery<TimeseriesResponse>(
    'timeseries',
    '/api/v1/timeseries',
    timeseriesFilters,
  );

  if (isLoading) {
    return (
      <div className="bg-dashboard-card border border-dashboard-border rounded-lg p-4 h-64 flex items-center justify-center text-dashboard-muted">
        Loading time series...
      </div>
    );
  }

  if (!data?.buckets?.length) {
    return (
      <div className="bg-dashboard-card border border-dashboard-border rounded-lg p-4 h-64 flex items-center justify-center text-dashboard-muted">
        No data in selected time range
      </div>
    );
  }

  const chartData = data.buckets.map((b) => ({
    minute: b.event_minute.slice(11, 16),
    event_count: b.event_count,
    decline_rate: b.decline_rate ?? 0,
    avg_latency_ms: b.avg_latency_ms ?? 0,
  }));

  return (
    <div className="bg-dashboard-card border border-dashboard-border rounded-lg p-4">
      <h3 className="text-sm font-medium text-dashboard-muted mb-3">Event Volume & Decline Rate</h3>
      <ResponsiveContainer width="100%" height={280}>
        <ComposedChart data={chartData}>
          <CartesianGrid strokeDasharray="3 3" stroke="#334155" />
          <XAxis dataKey="minute" tick={{ fontSize: 11, fill: '#94a3b8' }} />
          <YAxis yAxisId="left" tick={{ fontSize: 11, fill: '#94a3b8' }} />
          <YAxis yAxisId="right" orientation="right" domain={[0, 100]} tick={{ fontSize: 11, fill: '#94a3b8' }} />
          <Tooltip
            contentStyle={{ backgroundColor: '#1e293b', border: '1px solid #334155' }}
            labelStyle={{ color: '#94a3b8' }}
          />
          <Bar yAxisId="left" dataKey="event_count" fill="#3b82f6" opacity={0.7} name="Events" />
          <Line yAxisId="right" type="monotone" dataKey="decline_rate" stroke="#ef4444" strokeWidth={2} dot={false} name="Decline %" />
        </ComposedChart>
      </ResponsiveContainer>
    </div>
  );
}
