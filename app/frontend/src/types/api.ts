/** API response types matching backend Pydantic models (spec Section 5). */

export interface FreshnessInfo {
  last_raw_ts: string | null;
  last_serve_ts: string | null;
}

export interface ScenarioInfo {
  profile: 'baseline' | 'issuer_outage' | 'merchant_decline_spike' | 'latency_spike' | 'unknown';
  time_remaining_sec: number | null;
  events_per_sec: number;
}

export interface SummaryResponse {
  current_events: number | null;
  current_approval_rate: number | null;
  current_decline_rate: number | null;
  current_avg_latency_ms: number | null;
  prev_events: number | null;
  prev_approval_rate: number | null;
  prev_decline_rate: number | null;
  prev_avg_latency_ms: number | null;
  freshness: FreshnessInfo;
  scenario: ScenarioInfo;
}

export interface TimeseriesBucket {
  event_minute: string;
  event_count: number;
  decline_rate: number | null;
  avg_latency_ms: number | null;
}

export interface TimeseriesResponse {
  buckets: TimeseriesBucket[];
}

export interface BreakdownRow {
  dimension_value: string;
  events: number;
  decline_rate: number | null;
  avg_latency_ms: number | null;
  events_delta: number | null;
  decline_rate_delta: number | null;
  latency_delta: number | null;
}

export interface BreakdownResponse {
  dimension: string;
  rows: BreakdownRow[];
}

export interface EventRow {
  event_ts: string;
  event_id: string;
  payment_id: string;
  env: string;
  merchant_id: string;
  merchant_name: string;
  region: string;
  country: string;
  card_brand: string;
  issuer_bin: string;
  payment_method: string;
  amount: number;
  currency: string;
  auth_status: string;
  decline_code: string | null;
  auth_latency_ms: number;
}

export interface EventsResponse {
  events: EventRow[];
  total_count: number;
}

export interface HistogramBucket {
  label: string;
  count: number;
}

export interface LatencyStats {
  avg: number | null;
  min: number | null;
  max: number | null;
  p50: number | null;
  p95: number | null;
  p99: number | null;
  event_count: number;
}

export interface LatencyResponse {
  histogram: HistogramBucket[];
  statistics: LatencyStats;
}

export interface FiltersResponse {
  envs: string[];
  merchant_ids: string[];
  merchant_names: string[];
  regions: string[];
  countries: string[];
  card_brands: string[];
  issuer_bins: string[];
  payment_methods: string[];
}

export interface DashboardFilters {
  time_range: number;
  env: string | null;
  merchant_id: string | null;
  region: string | null;
  card_brand: string | null;
  auth_status: string | null;
}
