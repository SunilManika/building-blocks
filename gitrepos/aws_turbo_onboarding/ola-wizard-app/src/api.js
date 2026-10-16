// Thin fetch wrapper: JSON in/out, request timeouts and readable errors for network failures.
const DEFAULT_TIMEOUT_MS = 120_000; // Turbonomic calls page through large inventories

async function request(url, options = {}) {
  const { timeoutMs = DEFAULT_TIMEOUT_MS, signal, ...rest } = options;
  const headers = rest.body ? { 'Content-Type': 'application/json' } : {};

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(Object.assign(new Error('timeout'), { name: 'TimeoutError' })), timeoutMs);
  if (signal) signal.addEventListener('abort', () => ctrl.abort(signal.reason), { once: true });

  let res;
  try {
    res = await fetch(url, {
      credentials: 'same-origin',
      ...rest,
      headers,
      body: rest.body ? JSON.stringify(rest.body) : undefined,
      signal: ctrl.signal,
    });
  } catch (e) {
    if (signal?.aborted) throw e; // the caller cancelled on purpose
    const timedOut = e?.name === 'TimeoutError' || ctrl.signal.aborted;
    throw Object.assign(
      new Error(timedOut ? 'The server took too long to answer. Try again.' : 'Cannot reach the wizard server. Check that it is running and your connection is up.'),
      { network: true, data: {} }
    );
  } finally {
    clearTimeout(timer);
  }

  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw Object.assign(new Error(data.message || `Request failed (HTTP ${res.status})`), { data, status: res.status });
  }
  return data;
}

export const api = {
  testTurbonomic: (body) => request('/api/turbonomic/test', { method: 'POST', body }),
  scopes: (turbonomic) => request('/api/turbonomic/scopes', { method: 'POST', body: turbonomic }),
  addTarget: (body) => request('/api/turbonomic/targets', { method: 'POST', body }),
  wmiTargets: (turbonomic) => request('/api/turbonomic/targets/wmi', { method: 'POST', body: turbonomic }),
  targetStatuses: (turbonomic, uuids) => request('/api/turbonomic/targets/status', { method: 'POST', body: { turbonomic, uuids } }),
  scopeMembers: (turbonomic, uuids) => request('/api/turbonomic/scopes/members', { method: 'POST', body: { turbonomic, uuids } }),
  linuxVms: (turbonomic) => request('/api/turbonomic/vms/linux', { method: 'POST', body: turbonomic }),
  sqlVms: (turbonomic) => request('/api/turbonomic/vms/sql', { method: 'POST', body: turbonomic }),

  getConfig: () => request('/api/config', { timeoutMs: 15_000 }),
  saveConfig: (body) => request('/api/config', { method: 'POST', body, timeoutMs: 30_000 }),

  startRun: (body) => request('/api/runs', { method: 'POST', body, timeoutMs: 30_000 }),
  getRun: (id, from) => request(`/api/runs/${encodeURIComponent(id)}?from=${from}`, { timeoutMs: 15_000 }),
  listRuns: () => request('/api/runs', { timeoutMs: 15_000 }),
  cancelRun: (id) => request(`/api/runs/${encodeURIComponent(id)}/cancel`, { method: 'POST', body: {}, timeoutMs: 15_000 }),
  reports: () => request('/api/reports', { timeoutMs: 15_000 }),
};
