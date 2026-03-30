import { useQuery, UseQueryResult } from '@tanstack/react-query';
import type { DashboardFilters } from '../types/api';

const POLL_INTERVAL = 15_000; // 15-second refetchInterval

function buildQueryString(filters: DashboardFilters): string {
  const params = new URLSearchParams();
  params.set('time_range', String(filters.time_range));
  if (filters.env) params.set('env', filters.env);
  if (filters.merchant_id) params.set('merchant_id', filters.merchant_id);
  if (filters.region) params.set('region', filters.region);
  if (filters.card_brand) params.set('card_brand', filters.card_brand);
  if (filters.auth_status) params.set('auth_status', filters.auth_status);
  return params.toString();
}

async function fetchApi<T>(path: string): Promise<T> {
  const res = await fetch(path);
  if (!res.ok) throw new Error(`API error ${res.status}: ${res.statusText}`);
  return res.json();
}

export function useApiQuery<T>(
  key: string,
  path: string,
  filters?: DashboardFilters,
  enabled: boolean = true,
): UseQueryResult<T> {
  const qs = filters ? buildQueryString(filters) : '';
  const fullPath = qs ? `${path}?${qs}` : path;

  return useQuery<T>({
    queryKey: [key, fullPath],
    queryFn: () => fetchApi<T>(fullPath),
    refetchInterval: POLL_INTERVAL,
    enabled,
  });
}
