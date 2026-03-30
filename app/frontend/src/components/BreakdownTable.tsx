import { useState } from 'react';
import type { DashboardFilters, BreakdownResponse, BreakdownRow } from '../types/api';
import { useApiQuery } from '../hooks/useApiQuery';

interface Props {
  filters: DashboardFilters;
}

const DIMENSIONS = [
  { key: 'merchant_id', label: 'Merchant' },
  { key: 'region', label: 'Region' },
  { key: 'issuer_bin', label: 'Issuer BIN' },
  { key: 'card_brand', label: 'Card Brand' },
];

type SortKey = 'events' | 'decline_rate' | 'avg_latency_ms';

export default function BreakdownTable({ filters }: Props) {
  const [dimension, setDimension] = useState('merchant_id');
  const [sortBy, setSortBy] = useState<SortKey>('events');
  const [sortAsc, setSortAsc] = useState(false);

  const { data } = useApiQuery<BreakdownResponse>(
    `breakdown-${dimension}`,
    `/api/v1/breakdown?dimension=${dimension}`,
    filters,
  );

  const handleSort = (key: SortKey) => {
    if (sortBy === key) {
      setSortAsc(!sortAsc);
    } else {
      setSortBy(key);
      setSortAsc(false);
    }
  };

  const rows = [...(data?.rows ?? [])].sort((a, b) => {
    const aVal = a[sortBy] ?? 0;
    const bVal = b[sortBy] ?? 0;
    return sortAsc ? aVal - bVal : bVal - aVal;
  });

  return (
    <div className="bg-dashboard-card border border-dashboard-border rounded-lg p-4">
      <div className="flex gap-2 mb-3">
        {DIMENSIONS.map((d) => (
          <button
            key={d.key}
            className={`px-3 py-1 rounded text-sm ${
              dimension === d.key
                ? 'bg-dashboard-accent text-white'
                : 'bg-dashboard-bg text-dashboard-muted border border-dashboard-border'
            }`}
            onClick={() => setDimension(d.key)}
          >
            {d.label}
          </button>
        ))}
      </div>
      <table className="w-full text-sm">
        <thead>
          <tr className="text-dashboard-muted border-b border-dashboard-border">
            <th className="text-left py-2">Dimension</th>
            <th className="text-right py-2 cursor-pointer" onClick={() => handleSort('events')}>
              Events {sortBy === 'events' && (sortAsc ? '↑' : '↓')}
            </th>
            <th className="text-right py-2 cursor-pointer" onClick={() => handleSort('decline_rate')}>
              Decline % {sortBy === 'decline_rate' && (sortAsc ? '↑' : '↓')}
            </th>
            <th className="text-right py-2 cursor-pointer" onClick={() => handleSort('avg_latency_ms')}>
              Latency {sortBy === 'avg_latency_ms' && (sortAsc ? '↑' : '↓')}
            </th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r: BreakdownRow) => (
            <tr key={r.dimension_value} className="border-b border-dashboard-border/50 hover:bg-dashboard-bg/50">
              <td className="py-2">{r.dimension_value}</td>
              <td className="text-right py-2">
                {r.events.toLocaleString()}
                {r.events_delta != null && (
                  <span className={`ml-1 text-xs ${r.events_delta > 0 ? 'text-dashboard-success' : r.events_delta < 0 ? 'text-dashboard-danger' : 'text-dashboard-muted'}`}>
                    {r.events_delta > 0 ? '+' : ''}{r.events_delta}
                  </span>
                )}
              </td>
              <td className="text-right py-2">
                {r.decline_rate?.toFixed(1) ?? '--'}%
              </td>
              <td className="text-right py-2">
                {r.avg_latency_ms?.toFixed(0) ?? '--'}ms
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
