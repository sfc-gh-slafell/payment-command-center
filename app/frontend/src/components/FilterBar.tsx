import type { DashboardFilters, FiltersResponse } from '../types/api';
import { useApiQuery } from '../hooks/useApiQuery';

interface Props {
  filters: DashboardFilters;
  onChange: (filters: DashboardFilters) => void;
}

const TIME_RANGES = [
  { label: 'Last 15m', value: 15 },
  { label: 'Last 30m', value: 30 },
  { label: 'Last 1h', value: 60 },
  { label: 'Last 2h', value: 120 },
];

export default function FilterBar({ filters, onChange }: Props) {
  const { data: filterOptions } = useApiQuery<FiltersResponse>(
    'filters',
    '/api/v1/filters',
  );

  const update = (patch: Partial<DashboardFilters>) =>
    onChange({ ...filters, ...patch });

  return (
    <div className="sticky top-0 z-50 bg-dashboard-card border-b border-dashboard-border px-4 py-3">
      <div className="flex flex-wrap gap-3 items-center">
        {/* Time range dropdown */}
        <select
          className="bg-dashboard-bg border border-dashboard-border rounded px-2 py-1 text-sm"
          value={filters.time_range}
          onChange={(e) => update({ time_range: Number(e.target.value) })}
        >
          {TIME_RANGES.map((tr) => (
            <option key={tr.value} value={tr.value}>{tr.label}</option>
          ))}
        </select>

        {/* Environment */}
        <select
          className="bg-dashboard-bg border border-dashboard-border rounded px-2 py-1 text-sm"
          value={filters.env ?? ''}
          onChange={(e) => update({ env: e.target.value || null })}
        >
          <option value="">All Environments</option>
          {filterOptions?.envs?.map((e) => (
            <option key={e} value={e}>{e}</option>
          ))}
        </select>

        {/* Merchant searchable dropdown */}
        <select
          className="bg-dashboard-bg border border-dashboard-border rounded px-2 py-1 text-sm"
          value={filters.merchant_id ?? ''}
          onChange={(e) => update({ merchant_id: e.target.value || null })}
        >
          <option value="">All Merchants</option>
          {filterOptions?.merchant_ids?.map((m) => (
            <option key={m} value={m}>{m}</option>
          ))}
        </select>

        {/* Region multi-select */}
        <select
          className="bg-dashboard-bg border border-dashboard-border rounded px-2 py-1 text-sm"
          value={filters.region ?? ''}
          onChange={(e) => update({ region: e.target.value || null })}
        >
          <option value="">All Regions</option>
          {['NA', 'EU', 'APAC', 'LATAM'].map((r) => (
            <option key={r} value={r}>{r}</option>
          ))}
        </select>

        {/* Card brand */}
        <select
          className="bg-dashboard-bg border border-dashboard-border rounded px-2 py-1 text-sm"
          value={filters.card_brand ?? ''}
          onChange={(e) => update({ card_brand: e.target.value || null })}
        >
          <option value="">All Card Brands</option>
          {filterOptions?.card_brands?.map((b) => (
            <option key={b} value={b}>{b}</option>
          ))}
        </select>

        {/* Auth status */}
        <select
          className="bg-dashboard-bg border border-dashboard-border rounded px-2 py-1 text-sm"
          value={filters.auth_status ?? ''}
          onChange={(e) => update({ auth_status: e.target.value || null })}
        >
          <option value="">All Statuses</option>
          {['APPROVED', 'DECLINED', 'ERROR', 'TIMEOUT'].map((s) => (
            <option key={s} value={s}>{s}</option>
          ))}
        </select>
      </div>
    </div>
  );
}
