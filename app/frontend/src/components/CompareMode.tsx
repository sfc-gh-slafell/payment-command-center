import { useState } from 'react';
import type { DashboardFilters, SummaryResponse, BreakdownResponse } from '../types/api';
import { useApiQuery } from '../hooks/useApiQuery';

interface Props {
  filters: DashboardFilters;
}

const DIMENSIONS = [
  { key: 'merchant_id', label: 'Merchant' },
  { key: 'region', label: 'Region' },
  { key: 'card_brand', label: 'Card Brand' },
  { key: 'issuer_bin', label: 'Issuer BIN' },
] as const;

type DimensionKey = (typeof DIMENSIONS)[number]['key'];

function DeltaRow({
  label,
  current,
  prev,
  unit,
  invertColor,
}: {
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
  const [dimension, setDimension] = useState<DimensionKey>('region');

  // Single API call — summary response includes both current_* and prev_* window fields.
  // The previous window covers [time_range..2*time_range] ago from the same query.
  const { data } = useApiQuery<SummaryResponse>('summary-compare', '/api/v1/summary', filters);

  // Dimension drill-down: uses breakdown endpoint which also returns delta vs previous period
  const { data: breakdown } = useApiQuery<BreakdownResponse>(
    `compare-breakdown-${dimension}`,
    `/api/v1/breakdown?dimension=${dimension}`,
    filters,
  );

  return (
    <div className="bg-dashboard-card border border-dashboard-border rounded-lg p-4">
      <h3 className="text-sm font-medium text-dashboard-muted mb-3">
        Compare: Current {filters.time_range}m vs Previous {filters.time_range}m
      </h3>

      {/* Top-level KPI period-over-period comparison */}
      <DeltaRow
        label="Approval Rate"
        current={data?.current_approval_rate ?? null}
        prev={data?.prev_approval_rate ?? null}
        unit="%"
      />
      <DeltaRow
        label="Decline Rate"
        current={data?.current_decline_rate ?? null}
        prev={data?.prev_decline_rate ?? null}
        unit="%"
        invertColor
      />
      <DeltaRow
        label="Avg Latency"
        current={data?.current_avg_latency_ms ?? null}
        prev={data?.prev_avg_latency_ms ?? null}
        unit="ms"
        invertColor
      />
      <DeltaRow
        label="Event Volume"
        current={data?.current_events ?? null}
        prev={data?.prev_events ?? null}
        unit=""
      />

      {/* Dimension drill-down */}
      <div className="mt-4">
        <div className="flex items-center justify-between mb-2">
          <span className="text-xs text-dashboard-muted font-medium">Drill-down by</span>
          <div className="flex gap-1">
            {DIMENSIONS.map((d) => (
              <button
                key={d.key}
                className={`px-2 py-0.5 rounded text-xs ${
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
        </div>

        {/* Side-by-side: current decline rate vs previous period delta */}
        <div className="space-y-0.5 max-h-36 overflow-y-auto">
          <div className="flex justify-between text-xs text-dashboard-muted py-0.5 border-b border-dashboard-border/30">
            <span>Value</span>
            <div className="flex gap-4">
              <span>Decline %</span>
              <span className="w-12 text-right">Δ</span>
            </div>
          </div>
          {breakdown?.rows.slice(0, 8).map((row) => {
            const delta = row.decline_rate_delta;
            const deltaColor =
              delta == null
                ? 'text-dashboard-muted'
                : delta > 1
                ? 'text-dashboard-danger'
                : delta < -1
                ? 'text-dashboard-success'
                : 'text-dashboard-muted';

            return (
              <div
                key={row.dimension_value}
                className="flex justify-between items-center text-xs py-0.5"
              >
                <span className="text-dashboard-muted truncate max-w-[110px]">
                  {row.dimension_value}
                </span>
                <div className="flex gap-4 items-center">
                  <span className="font-mono">
                    {row.decline_rate?.toFixed(1) ?? '--'}%
                  </span>
                  <span className={`font-mono w-12 text-right ${deltaColor}`}>
                    {delta != null
                      ? `${delta > 0 ? '+' : ''}${delta.toFixed(1)}`
                      : '--'}
                  </span>
                </div>
              </div>
            );
          })}
          {(!breakdown?.rows || breakdown.rows.length === 0) && (
            <span className="text-xs text-dashboard-muted">No data</span>
          )}
        </div>
      </div>
    </div>
  );
}
