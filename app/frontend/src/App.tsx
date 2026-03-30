import { useState } from 'react';
import type { DashboardFilters } from './types/api';
import FilterBar from './components/FilterBar';
import KPIStrip from './components/KPIStrip';
import TimeSeriesChart from './components/TimeSeriesChart';
import BreakdownTable from './components/BreakdownTable';
import RecentFailures from './components/RecentFailures';
import CompareMode from './components/CompareMode';
import LatencyPanel from './components/LatencyPanel';
import FreshnessWidget from './components/FreshnessWidget';

const DEFAULT_FILTERS: DashboardFilters = {
  time_range: 15,
  env: null,
  merchant_id: null,
  region: null,
  card_brand: null,
  auth_status: null,
};

export default function App() {
  const [filters, setFilters] = useState<DashboardFilters>(DEFAULT_FILTERS);

  return (
    <div className="min-h-screen bg-dashboard-bg text-dashboard-text">
      {/* Filter bar — persistent top */}
      <FilterBar filters={filters} onChange={setFilters} />

      {/* KPI strip */}
      <div className="px-4 py-2">
        <KPIStrip filters={filters} />
      </div>

      {/* Main grid layout */}
      <div className="grid grid-cols-12 gap-4 px-4 pb-4">
        {/* Time series — full width */}
        <div className="col-span-12">
          <TimeSeriesChart filters={filters} />
        </div>

        {/* Breakdown table + Recent failures */}
        <div className="col-span-8">
          <BreakdownTable filters={filters} />
        </div>
        <div className="col-span-4">
          <RecentFailures filters={filters} />
        </div>

        {/* Compare mode + Latency panel + Freshness widget */}
        <div className="col-span-4">
          <CompareMode filters={filters} />
        </div>
        <div className="col-span-4">
          <LatencyPanel filters={filters} />
        </div>
        <div className="col-span-4">
          <FreshnessWidget filters={filters} />
        </div>
      </div>
    </div>
  );
}
