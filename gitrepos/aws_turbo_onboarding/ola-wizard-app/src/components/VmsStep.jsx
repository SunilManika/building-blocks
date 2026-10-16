import React, { useEffect, useRef, useState } from 'react';
import AddVmModal from './AddVmModal.jsx';
import { emptyVm, validateVm } from '../validation.js';
import { api } from '../api.js';

export default function VmsStep({ state, setState, next, back, addedTargets, removedVms, setRemovedVms }) {
  // editing: null = closed, otherwise the index being edited.
  const [editing, setEditing] = useState(null);
  // addingLinux: true when the "Add Linux VM" modal is open for a brand-new entry.
  const [addingLinux, setAddingLinux] = useState(false);
  // VMs that belong to the scope(s) of the targets from step 2: { loading, names: string[], error }.
  const [scopeVms, setScopeVms] = useState({ loading: true, names: [], error: '' });
  const [reloadKey, setReloadKey] = useState(0);

  // Scopes of the targets added this session, or the saved scope from config.json when none were added.
  const scopeIds = [...new Set(
    addedTargets.length > 0 ? addedTargets.map((t) => t.scope).filter(Boolean) : [state.wmi.scope_uuid].filter(Boolean)
  )].join(',');

  // Names (lower-case) the user removed from the inventory. Kept in App so it survives leaving this tab; the ref
  // lets the async load below see the latest value.
  const removedRef = useRef(removedVms);
  removedRef.current = removedVms;

  // Add every VM discovered in the targets' scopes to the inventory (Windows, address taken from Turbonomic).
  // VMs already in the inventory keep their settings; an empty address is filled in from Turbonomic.
  // VMs the user removed are not added back.
  const populate = (found) => setState((s) => {
    const byName = new Map(s.vms.map((v, i) => [String(v.vm_name).trim().toLowerCase(), i]));
    const vms = s.vms.map((v) => ({ ...v }));
    for (const d of found) {
      const k = String(d.name).trim().toLowerCase();
      const i = byName.get(k);
      if (i === undefined) {
        if (!removedRef.current.includes(k)) vms.push({ ...emptyVm(), vm_name: d.name, address: d.address || '', os: 'Windows' });
      } else if (!vms[i].address && d.address) {
        vms[i].address = d.address;
      }
    }
    return { ...s, vms };
  });

  useEffect(() => {
    if (!scopeIds) { setScopeVms({ loading: false, names: [], error: '' }); return undefined; }
    let stopped = false;
    setScopeVms({ loading: true, names: [], error: '' });
    api.scopeMembers(state.turbonomic, scopeIds.split(','))
      .then((r) => {
        if (stopped) return;
        setScopeVms({ loading: false, names: r.ok ? r.vms : [], error: r.ok ? '' : r.message });
        if (r.ok) populate(r.details || r.vms.map((name) => ({ name, address: '' })));
      })
      .catch((e) => { if (!stopped) setScopeVms({ loading: false, names: [], error: e.data?.message || e.message }); });
    return () => { stopped = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scopeIds, reloadKey]);

  const key = (n) => String(n).trim().toLowerCase();
  const inTarget = new Set(scopeVms.names.map(key));

  // Windows VMs must be in the target scope; Linux VMs added manually are always kept.
  const keep = (vm) => vm.os === 'Linux' || inTarget.has(key(vm.vm_name));

  const names = (skip) => state.vms.filter((_, i) => i !== skip).map((v) => v.vm_name);
  const rows = state.vms
    .map((vm, i) => ({ vm, i, ok: validateVm(vm, names(i)).valid }))
    .filter((r) => keep(r.vm));
  const loading = scopeVms.loading;
  const valid = !loading && rows.length > 0 && rows.every((r) => r.ok);

  // Target VMs that are not in the inventory yet (offered when editing a row).
  const used = new Set(state.vms.map((v) => key(v.vm_name)));
  const available = scopeVms.names.filter((n) => !used.has(key(n)));

  // Drop Windows VMs not in the target scope before proceeding; keep all Linux VMs.
  const proceed = () => {
    setState((s) => ({ ...s, vms: s.vms.filter(keep) }));
    next();
  };

  const choicesFor = () => [state.vms[editing].vm_name, ...available];

  const save = (vm) => {
    const old = state.vms[editing];
    // Picking another VM name replaces the old one, which must not reappear; picking a removed VM brings it back.
    setRemovedVms((r) => {
      const next = new Set(r);
      if (old && old.os === 'Windows' && key(old.vm_name) !== key(vm.vm_name)) next.add(key(old.vm_name));
      next.delete(key(vm.vm_name));
      return [...next];
    });
    setState((s) => ({ ...s, vms: s.vms.map((x, i) => (i === editing ? vm : x)) }));
    setEditing(null);
  };

  const saveNewLinux = (vm) => {
    setState((s) => ({ ...s, vms: [...s.vms, vm] }));
    setAddingLinux(false);
  };

  const remove = (i) => {
    const vm = state.vms[i];
    if (vm && vm.os === 'Windows') setRemovedVms((r) => (r.includes(key(vm.vm_name)) ? r : [...r, key(vm.vm_name)]));
    setState((s) => ({ ...s, vms: s.vms.filter((_, idx) => idx !== i) }));
  };

  // Removed VMs that still belong to the target scope can be brought back.
  const restorable = removedVms.filter((k) => inTarget.has(k)).length;
  const restore = () => {
    setRemovedVms([]);
    removedRef.current = [];
    setReloadKey((k) => k + 1); // reloads the scope, which re-adds the restored VMs
  };

  return (
    <>
      <div className="card">
        <h2>3. VMs inventory</h2>
        <p className="lead">
          Windows VMs are populated from the target scope in step 2. Use <strong>Add Linux VM</strong> to manually
          add Linux hosts with SSH credentials. Click <strong>Edit</strong> on any row to update its settings.
        </p>

        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', margin: '16px 0 8px' }}>
          <h3 style={{ margin: 0 }}>VMs</h3>
          <div>
            {restorable > 0 && (
              <button className="btn sm" onClick={restore} disabled={loading} style={{ marginRight: 8 }}>
                Restore {restorable} removed VM{restorable === 1 ? '' : 's'}
              </button>
            )}
            <button className="btn sm" onClick={() => setAddingLinux(true)}>+ Add Linux VM</button>
          </div>
        </div>

        {loading && <div className="sub" style={{ marginTop: 10 }}>Loading VMs from Turbonomic...</div>}
        {scopeVms.error && (
          <div className="notice bad" role="alert">
            {scopeVms.error} <button className="btn sm" onClick={() => setReloadKey((k) => k + 1)}>Retry</button>
          </div>
        )}
        <table style={{ marginTop: 12 }}>
          <thead>
            <tr>
              <th>VM name</th>
              <th>IP / hostname</th>
              <th>OS</th>
              <th>Domain / SSH user</th>
              <th>Status</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {rows.map(({ vm, i, ok }) => (
              <tr key={i}>
                <td>{vm.vm_name}</td>
                <td className="mono">{vm.address}</td>
                <td>{vm.os}</td>
                <td className="mono">{vm.os === 'Windows' ? vm.domain : vm.ssh_username}</td>
                <td><span className={`badge ${ok ? 'ok' : 'bad'}`}>{ok ? 'Ready' : 'Incomplete'}</span></td>
                <td style={{ whiteSpace: 'nowrap' }}>
                  <button className="btn sm" onClick={() => setEditing(i)}>Edit</button>{' '}
                  <button className="btn sm danger" onClick={() => remove(i)}>Remove</button>
                </td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr>
                <td colSpan={6} className="sub">
                  {loading ? 'Loading...' : 'No VMs found in the target scope. Click \u201cAdd Linux VM\u201d to add one manually.'}
                </td>
              </tr>
            )}
          </tbody>
        </table>
        {rows.some((r) => !r.ok) && (
          <div className="notice warn">Some VMs are incomplete. Click <strong>Edit</strong> to fix them, or <strong>Remove</strong> them.</div>
        )}
      </div>

      <div className="nav">
        <button className="btn" onClick={back}>Back</button>
        <button
          className="btn primary"
          onClick={proceed}
          disabled={!valid}
          title={valid ? '' : 'Complete all rows (at least one VM is required)'}
        >
          Save &amp; continue
        </button>
      </div>

      {/* Edit existing VM */}
      {editing !== null && (
        <AddVmModal
          initial={state.vms[editing]}
          otherNames={names(editing)}
          vmChoices={choicesFor()}
          onClose={() => setEditing(null)}
          onSave={save}
        />
      )}

      {/* Add new Linux VM */}
      {addingLinux && (
        <AddVmModal
          initial={null}
          otherNames={names(-1)}
          vmChoices={[]}
          fixedOs="Linux"
          onClose={() => setAddingLinux(false)}
          onSave={saveNewLinux}
        />
      )}
    </>
  );
}
