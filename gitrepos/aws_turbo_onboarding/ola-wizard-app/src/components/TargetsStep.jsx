import React, { useEffect, useRef, useState } from 'react';
import AddTargetModal from './AddTargetModal.jsx';
import { api } from '../api.js';

const POLL_MS = 5000;
const POLL_GIVE_UP_MS = 10 * 60 * 1000;
// Turbonomic reports these while a target is still being created/validated/discovered.
const IN_PROGRESS = /discover|validat|pending|creat|added|refresh|in progress/i;
const isDone = (s) => !!s && (/fail|^discovered$/i.test(s) || !IN_PROGRESS.test(s));
const badgeClass = (s) => (/^(normal|validated|discovered)$/i.test(s || '') ? 'ok' : isDone(s) ? 'bad' : 'warn');

export default function TargetsStep({ state, setState, next, back, addedTargets, setAddedTargets }) {
  const [open, setOpen] = useState(false);
  const [pollError, setPollError] = useState('');
  const [pollKey, setPollKey] = useState(0); // bump to restart polling after it gave up
  const [gaveUp, setGaveUp] = useState(false);
  const [loadState, setLoadState] = useState({ loading: true, error: '' });
  const [reloadKey, setReloadKey] = useState(0);
  const w = state.wmi;

  // Pre-populate with the WMI targets that already exist on the Turbonomic server.
  useEffect(() => {
    let cancelled = false;
    setLoadState({ loading: true, error: '' });
    api.wmiTargets(state.turbonomic)
      .then((r) => {
        if (cancelled) return;
        if (!r.ok) { setLoadState({ loading: false, error: r.message }); return; }
        setAddedTargets((local) => {
          const byUuid = new Map(local.map((t) => [t.uuid, t]));
          const fromServer = r.targets.map((t) => ({ ...t, ...byUuid.get(t.uuid), status: t.status }));
          const serverIds = new Set(r.targets.map((t) => t.uuid));
          return [...fromServer, ...local.filter((t) => !serverIds.has(t.uuid))];
        });
        // Without a saved WMI account, adopt the account/scope of the first healthy existing target (password is never returned).
        const pick = r.targets.find((t) => /^discovered$/i.test(t.status)) || r.targets[0];
        if (pick) {
          setState((s) => (s.wmi.username ? s : { ...s, wmi: { ...s.wmi, username: pick.username, use_ntlm: pick.useNtlm, scope_uuid: pick.scope } }));
        }
        setLoadState({ loading: false, error: '' });
      })
      .catch((e) => !cancelled && setLoadState({ loading: false, error: e.data?.message || e.message }));
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [reloadKey]);

  // Keep the latest values reachable from the interval without restarting it on every render.
  const latest = useRef({});
  latest.current = { turbonomic: state.turbonomic, targets: addedTargets };

  const pendingIds = addedTargets.filter((t) => t.uuid && !isDone(t.status)).map((t) => t.uuid).join(',');

  useEffect(() => {
    if (!pendingIds) { setGaveUp(false); return undefined; }
    let stopped = false;
    let inFlight = false;
    const started = Date.now();
    setGaveUp(false);

    const tick = async () => {
      if (stopped || inFlight) return;
      if (Date.now() - started > POLL_GIVE_UP_MS) { setGaveUp(true); stopped = true; clearInterval(timer); return; }
      const uuids = latest.current.targets.filter((t) => t.uuid && !isDone(t.status)).map((t) => t.uuid);
      if (uuids.length === 0) return;
      inFlight = true;
      try {
        const r = await api.targetStatuses(latest.current.turbonomic, uuids);
        if (stopped) return;
        if (r.ok) {
          setPollError('');
          setAddedTargets((list) => list.map((t) => (r.statuses[t.uuid] ? { ...t, status: r.statuses[t.uuid] } : t)));
        } else {
          setPollError(r.message || 'Could not refresh target status.');
        }
      } catch (e) {
        if (!stopped) setPollError(e.data?.message || e.message);
      } finally {
        inFlight = false;
      }
    };

    const timer = setInterval(tick, POLL_MS);
    tick();
    return () => { stopped = true; clearInterval(timer); };
  }, [pendingIds, pollKey, setAddedTargets]);

  const onAdded = (t) => {
    setAddedTargets((list) => [...list, t]);
    // The newest target's account and scope are what the toolkit config uses for Windows VMs.
    setState((s) => ({ ...s, wmi: { ...s.wmi, username: t.username, password: t.password, use_ntlm: t.useNtlm, scope_uuid: t.scope } }));
    setOpen(false);
  };

  const hasTarget = addedTargets.length > 0 || !!(w.username && w.password);

  return (
    <>
      <div className="card">
        <h2>2. Targets</h2>
        <p className="lead">
          Add the WMI targets Turbonomic uses to discover Windows applications. Each target is created in your Turbonomic
          instance as soon as you add it.
        </p>

        <div className="run-actions" style={{ justifyContent: 'space-between' }}>
          <h3 style={{ margin: 0 }}>WMI targets</h3>
          <span>
            <button className="btn" onClick={() => setReloadKey((k) => k + 1)} disabled={loadState.loading}>{loadState.loading ? 'Loading...' : 'Refresh'}</button>{' '}
            <button className="btn primary" onClick={() => setOpen(true)}>Add Target</button>
          </span>
        </div>
        {loadState.error && (
          <div className="notice bad" role="alert">
            Could not load existing WMI targets from Turbonomic: {loadState.error} <button className="btn sm" onClick={() => setReloadKey((k) => k + 1)}>Retry</button>
          </div>
        )}

        <table style={{ marginTop: 12 }}>
          <thead><tr><th>Display name</th><th>Username</th><th>Scope</th><th>NTLM</th><th>Status</th></tr></thead>
          <tbody>
            {addedTargets.map((t) => (
              <tr key={t.uuid || t.displayName}>
                <td>{t.displayName}</td>
                <td className="mono">{t.username}</td>
                <td>{t.scopeName}</td>
                <td>{t.useNtlm ? 'Yes' : 'No'}</td>
                <td><span className={`badge ${badgeClass(t.status)}`}>{t.status || 'Added'}</span></td>
              </tr>
            ))}
            {addedTargets.length === 0 && (
              <tr><td colSpan={5} className="sub">
                {loadState.loading ? 'Loading existing WMI targets from Turbonomic...' : 'No WMI targets exist in Turbonomic yet. Click Add Target.'}
              </td></tr>
            )}
          </tbody>
        </table>
        {pendingIds && !gaveUp && <div className="sub" style={{ marginTop: 10 }}>Checking target status every {POLL_MS / 1000}s...</div>}
        {gaveUp && (
          <div className="notice warn">
            Status is still not final after 10 minutes. <button className="btn sm" onClick={() => setPollKey((k) => k + 1)}>Check again</button>
          </div>
        )}
        {pollError && <div className="notice bad" role="alert">Could not refresh target status: {pollError}</div>}
      </div>
      <div className="nav">
        <button className="btn" onClick={back}>Back</button>
        <button className="btn primary" onClick={next} disabled={!hasTarget} title={hasTarget ? '' : 'Add at least one target'}>Save &amp; continue</button>
      </div>

      {open && (
        <AddTargetModal
          turbonomic={state.turbonomic}
          existingNames={addedTargets.map((t) => t.displayName)}
          onClose={() => setOpen(false)}
          onAdded={onAdded}
        />
      )}
    </>
  );
}
