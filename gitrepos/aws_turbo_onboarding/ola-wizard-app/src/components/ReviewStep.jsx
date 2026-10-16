import React, { useState } from 'react';
import { api } from '../api.js';
import { buildConfig } from '../configModel.js';

export default function ReviewStep({ state, existing, setSaved, next, back }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const vms = state.vms;
  const windows = vms.filter((v) => v.os === 'Windows');
  const linux = vms.filter((v) => v.os === 'Linux');
  const list = (items) => items.map((v) => v.vm_name).join(', ') || '-';

  // config.json is written automatically when continuing to the Run step.
  const proceed = async () => {
    setBusy(true);
    setError('');
    try {
      await api.saveConfig(buildConfig(state, existing));
      setSaved(true);
      next();
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <div className="card">
        <h2>Review</h2>
        <p className="lead">Summary of the Turbonomic connection and the VMs that will be assessed.</p>
        <table style={{ marginBottom: 16 }}>
          <tbody>
            <tr><th style={{ width: 220 }}>Turbonomic host</th><td className="mono">{state.turbonomic.host || '-'}</td></tr>
            <tr><th>Windows VMs</th><td>{list(windows)}</td></tr>
            <tr><th>Linux VMs</th><td>{list(linux)}</td></tr>
          </tbody>
        </table>
        <table>
          <thead>
            <tr><th>VM name</th><th>Address</th><th>OS</th><th>Domain / SSH user</th></tr>
          </thead>
          <tbody>
            {vms.length === 0 && <tr><td colSpan={4}>No VMs added.</td></tr>}
            {vms.map((v, i) => (
              <tr key={i}>
                <td className="mono">{v.vm_name}</td>
                <td className="mono">{v.address || '-'}</td>
                <td>{v.os}</td>
                <td>{v.os === 'Windows' ? v.domain || '-' : v.ssh_username || '-'}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {error && <div className="notice bad">{error}</div>}
      </div>
      <div className="nav">
        <button className="btn" onClick={back}>Back</button>
        <button className="btn primary" onClick={proceed} disabled={busy}>{busy ? 'Saving...' : 'Continue to run'}</button>
      </div>
    </>
  );
}
