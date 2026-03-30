import { useState } from 'react';
import type { DashboardFilters, EventsResponse, EventRow } from '../types/api';
import { useApiQuery } from '../hooks/useApiQuery';

interface Props {
  filters: DashboardFilters;
}

function EventDetailModal({ event, onClose }: { event: EventRow; onClose: () => void }) {
  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50" onClick={onClose}>
      <div className="bg-dashboard-card border border-dashboard-border rounded-lg p-6 max-w-lg w-full mx-4" onClick={(e) => e.stopPropagation()}>
        <h3 className="text-lg font-medium mb-4">Event Detail</h3>
        <dl className="grid grid-cols-2 gap-2 text-sm">
          {Object.entries(event).map(([key, val]) => (
            <div key={key}>
              <dt className="text-dashboard-muted">{key}</dt>
              <dd className="font-mono">{val != null ? String(val) : '--'}</dd>
            </div>
          ))}
        </dl>
        <button className="mt-4 px-4 py-2 bg-dashboard-accent text-white rounded" onClick={onClose}>
          Close
        </button>
      </div>
    </div>
  );
}

export default function RecentFailures({ filters }: Props) {
  const [selected, setSelected] = useState<EventRow | null>(null);

  // Filter for DECLINED and ERROR statuses
  const failureFilters = { ...filters, auth_status: 'DECLINED' };
  const { data } = useApiQuery<EventsResponse>('recent-failures', '/api/v1/events', failureFilters);

  const events = data?.events ?? [];

  return (
    <div className="bg-dashboard-card border border-dashboard-border rounded-lg p-4 h-full">
      <h3 className="text-sm font-medium text-dashboard-muted mb-3">Recent Failures</h3>
      <div className="overflow-y-auto max-h-[400px]">
        <table className="w-full text-xs">
          <thead className="sticky top-0 bg-dashboard-card">
            <tr className="text-dashboard-muted border-b border-dashboard-border">
              <th className="text-left py-1">Time</th>
              <th className="text-left py-1">Merchant</th>
              <th className="text-right py-1">Amount</th>
              <th className="text-left py-1">Code</th>
            </tr>
          </thead>
          <tbody>
            {events.map((e) => (
              <tr
                key={e.event_id}
                className="border-b border-dashboard-border/30 cursor-pointer hover:bg-dashboard-bg/50"
                onClick={() => setSelected(e)}
              >
                <td className="py-1 font-mono">{e.event_ts.slice(11, 19)}</td>
                <td className="py-1">{e.merchant_id}</td>
                <td className="py-1 text-right">${e.amount.toFixed(2)}</td>
                <td className="py-1 text-dashboard-danger">{e.decline_code ?? e.auth_status}</td>
              </tr>
            ))}
            {events.length === 0 && (
              <tr><td colSpan={4} className="py-4 text-center text-dashboard-muted">No recent failures</td></tr>
            )}
          </tbody>
        </table>
      </div>
      {selected && <EventDetailModal event={selected} onClose={() => setSelected(null)} />}
    </div>
  );
}
