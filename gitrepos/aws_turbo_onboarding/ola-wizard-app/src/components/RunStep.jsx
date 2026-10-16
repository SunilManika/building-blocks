import React, { useEffect, useRef, useState } from 'react';
import { api } from '../api.js';

const statusClass = { running: 'warn', succeeded: 'ok', failed: 'bad', cancelled: 'muted' };
const MAX_POLL_FAILURES = 5;     // consecutive failed polls before we tell the user the connection is lost
const MAX_LOG_CHARS = 1_000_000; // keep the in-browser log bounded

export default function RunStep({ saved, back }) {
  const [days, setDays] = useState(1);
  const [run, setRun] = useState(null); // {id, command, status, output, truncated, timedOut}
  const [error, setError] = useState('');
  const [starting, setStarting] = useState(false);
  const [cancelling, setCancelling] = useState(false);
  const [lost, setLost] = useState(false); // polling keeps failing
  const [reports, setReports] = useState([]);
  const [reportsError, setReportsError] = useState('');
  const offset = useRef(0);
  const failures = useRef(0);
  const logEl = useRef(null);

  const daysValid = /^\d+$/.test(String(days)) && Number(days) >= 1 && Number(days) <= 90;

  const loadReports = () => api.reports()
    .then((r) => { setReports(r); setReportsError(''); })
    .catch((e) => setReportsError(e.message));

  const adopt = (id, command, status = 'running') => {
    offset.current = 0;
    failures.current = 0;
    setLost(false);
    setRun({ id, command, status, output: '', truncated: false, timedOut: false });
  };

  // On load (or after a page reload) pick up a run that is still going on the server.
  useEffect(() => {
    loadReports();
    api.listRuns()
      .then((r) => {
        const active = r.runs.find((x) => x.status === 'running');
        if (active) adopt(active.id, active.command);
      })
      .catch(() => {});
  }, []);

  useEffect(() => {
    if (!run || run.status !== 'running') return undefined;
    let stopped = false;
    let timer;
    const tick = async () => {
      try {
        const r = await api.getRun(run.id, offset.current);
        if (stopped) return;
        failures.current = 0;
        setLost(false);
        offset.current = r.offset;
        setRun((cur) => {
          if (!cur || cur.id !== run.id) return cur;
          const output = (cur.output + r.output).slice(-MAX_LOG_CHARS);
          return { ...cur, status: r.status, output, truncated: cur.truncated || r.truncated || output.length === MAX_LOG_CHARS, timedOut: r.timedOut };
        });
        if (r.status !== 'running') { loadReports(); return; }
      } catch (e) {
        if (stopped) return;
        if (e.status === 404) { // the server restarted and forgot the run
          setRun((cur) => (cur ? { ...cur, status: 'failed' } : cur));
          setError('The server no longer knows this run (it was probably restarted). Start the report again.');
          return;
        }
        failures.current += 1;
        if (failures.current >= MAX_POLL_FAILURES) setLost(true);
      }
      timer = setTimeout(tick, failures.current > 0 ? 4000 : 1500);
    };
    timer = setTimeout(tick, 800);
    return () => { stopped = true; clearTimeout(timer); };
  }, [run?.id, run?.status]);

  useEffect(() => {
    if (logEl.current) logEl.current.scrollTop = logEl.current.scrollHeight;
  }, [run?.output]);

  const start = async (kind) => {
    if (starting) return;
    setError('');
    setStarting(true);
    try {
      const r = await api.startRun({ kind, days: Number(days) });
      adopt(r.id, r.command);
    } catch (e) {
      if (e.data?.code === 'run_active' && e.data.runId) {
        adopt(e.data.runId, '');
        setError('A run is already in progress; showing it.');
      } else {
        setError(e.message);
      }
    } finally {
      setStarting(false);
    }
  };

  const cancel = async () => {
    if (!run || cancelling) return;
    if (!window.confirm('Stop the running report? Partial results will not be saved.')) return;
    setCancelling(true);
    try {
      const r = await api.cancelRun(run.id);
      setRun((cur) => (cur ? { ...cur, status: r.status } : cur));
      loadReports();
    } catch (e) {
      setError(e.message);
    } finally {
      setCancelling(false);
    }
  };

  const running = run?.status === 'running';
  const htmlReports = reports.filter((f) => /fleet-report.*\.html$/i.test(f.path));

  return (
    <>
      <div className="card">
        <h2>5. Run</h2>
        <p className="lead">Run the toolkit from this container.</p>
        {!saved && <div className="notice warn" style={{ marginBottom: 16 }}>Complete the Review step (4) before running; it writes config.json.</div>}

        <h3 style={{ marginTop: 0 }}>Generate fleet report</h3>
        <p className="sub">Runs <code>Invoke-FleetReport.ps1</code> (SQL Server inventory + Turbonomic metrics) with PowerShell.</p>
        <div className="run-actions">
          <label htmlFor="peak-days" style={{ margin: 0 }}>Peak window (days)</label>
          <input
            id="peak-days" type="number" min="1" max="90" step="1" inputMode="numeric" value={days}
            onChange={(e) => setDays(e.target.value)} style={{ width: 90 }}
            className={daysValid ? '' : 'invalid'} aria-invalid={!daysValid} disabled={running}
          />
          <button className="btn primary" disabled={!saved || running || starting || !daysValid} onClick={() => start('report')}>
            {starting ? 'Starting...' : 'Generate report'}
          </button>
          {running && <button className="btn danger" disabled={cancelling} onClick={cancel}>{cancelling ? 'Stopping...' : 'Stop'}</button>}
        </div>
        {!daysValid && <div className="field-error">Enter a whole number of days from 1 to 90.</div>}

        {error && <div className="notice bad" role="alert">{error}</div>}
        {lost && running && (
          <div className="notice warn" role="status">
            Lost contact with the server. The report keeps running there; this page retries automatically.
          </div>
        )}
        {run && (
          <>
            <div style={{ marginTop: 20 }}>
              <span className={`badge ${statusClass[run.status] || 'muted'}`}>{run.status}</span>{' '}
              <span className="sub mono">{run.command.replace(/-Password\S*\s+\S+/g, '')}</span>
            </div>
            {run.timedOut && <div className="notice bad">The run took too long and was stopped by the server.</div>}
            {run.truncated && <div className="notice warn">The log is very long; only the most recent output is shown.</div>}
            <pre className="log" ref={logEl} aria-live="off">{run.output || 'Waiting for output...'}</pre>
          </>
        )}

        <h3>Generated files</h3>
        {reportsError && <div className="notice bad">{reportsError}</div>}
        {htmlReports.length === 0 ? (
          <p className="sub">No fleet reports yet in <code>output/</code>.</p>
        ) : (
          <table>
            <thead><tr><th>File</th><th>Modified</th></tr></thead>
            <tbody>
              {htmlReports.map((f) => (
                <tr key={f.path}>
                  <td><a href={`/api/reports/file?path=${encodeURIComponent(f.path)}`} target="_blank" rel="noreferrer">{f.path}</a></td>
                  <td className="sub">{new Date(f.mtime).toLocaleString()}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
      <div className="nav">
        <button className="btn" onClick={back} disabled={running}>Back</button>
        <span />
      </div>
    </>
  );
}
