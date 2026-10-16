import React, { useEffect, useMemo, useRef, useState } from 'react';
import { api } from '../api.js';
import { validateWmiTarget } from '../validation.js';
import PasswordInput from './PasswordInput.jsx';

const EMPTY = { displayName: '', username: '', password: '', scope: '', useNtlm: true };

export default function AddTargetModal({ turbonomic, existingNames, onClose, onAdded }) {
  const [form, setForm] = useState(EMPTY);
  const [touched, setTouched] = useState({});
  const [submitted, setSubmitted] = useState(false);
  const [serverErrors, setServerErrors] = useState({});
  const [scopes, setScopes] = useState({ loading: true, items: [], error: '' });
  const [filter, setFilter] = useState('');
  const [busy, setBusy] = useState(false);
  const [formError, setFormError] = useState('');
  const firstField = useRef(null);

  const local = useMemo(() => validateWmiTarget(form), [form]);
  const localDup = existingNames.some((n) => n.toLowerCase() === form.displayName.trim().toLowerCase());
  const errors = {
    ...local.errors,
    ...(localDup && !local.errors.displayName ? { displayName: 'A target with this display name was already added.' } : {}),
  };
  const err = (f) => ((touched[f] || submitted) ? errors[f] : undefined) || serverErrors[f];

  const loadScopes = async () => {
    setScopes({ loading: true, items: [], error: '' });
    try {
      const r = await api.scopes(turbonomic);
      setScopes(r.ok ? { loading: false, items: r.scopes, error: '' } : { loading: false, items: [], error: r.message });
    } catch (e) {
      setScopes({ loading: false, items: [], error: e.data?.message || e.message });
    }
  };

  useEffect(() => {
    loadScopes();
    firstField.current?.focus();
    const onKey = (e) => { if (e.key === 'Escape' && !busy) onClose(); };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const set = (k) => (e) => {
    const v = e.target.type === 'checkbox' ? e.target.checked : e.target.value;
    setForm((f) => ({ ...f, [k]: v }));
    setServerErrors((s) => ({ ...s, [k]: undefined }));
    setFormError('');
  };
  const blur = (k) => () => setTouched((t) => ({ ...t, [k]: true }));

  const visibleScopes = useMemo(() => {
    const q = filter.trim().toLowerCase();
    const list = q ? scopes.items.filter((s) => s.name.toLowerCase().includes(q)) : scopes.items;
    // Keep the selected scope in the list even when the filter hides it.
    const sel = scopes.items.find((s) => s.uuid === form.scope);
    return sel && !list.includes(sel) ? [sel, ...list] : list;
  }, [scopes.items, filter, form.scope]);

  const submit = async (e) => {
    e.preventDefault();
    setSubmitted(true);
    if (!local.valid || localDup) return;
    setBusy(true);
    setFormError('');
    try {
      const r = await api.addTarget({ turbonomic, target: form });
      if (r.ok) {
        const scope = scopes.items.find((s) => s.uuid === form.scope);
        onAdded({ uuid: r.uuid, displayName: form.displayName.trim(), username: form.username, password: form.password, scope: form.scope, scopeName: scope?.name || form.scope, useNtlm: form.useNtlm, status: r.status });
      } else {
        setServerErrors(r.errors || {});
        setFormError(r.message);
      }
    } catch (ex) {
      setServerErrors(ex.data?.errors || {});
      setFormError(ex.data?.message || ex.message);
    } finally {
      setBusy(false);
    }
  };

  const text = (name, label, props = {}) => {
    const Input = props.type === 'password' ? PasswordInput : 'input';
    return (
    <div className="field">
      <label htmlFor={`t-${name}`}>{label} <span className="req">*</span></label>
      <Input
        id={`t-${name}`}
        ref={name === 'displayName' ? firstField : undefined}
        value={form[name]}
        onChange={set(name)}
        onBlur={blur(name)}
        className={err(name) ? 'invalid' : ''}
        aria-invalid={!!err(name)}
        aria-describedby={err(name) ? `t-${name}-err` : undefined}
        required
        {...props}
      />
      {err(name) && <div className="field-error" id={`t-${name}-err`}>{err(name)}</div>}
    </div>
    );
  };

  return (
    <div className="modal-backdrop" onMouseDown={(e) => { if (e.target === e.currentTarget && !busy) onClose(); }}>
      <form className="modal" role="dialog" aria-modal="true" aria-labelledby="add-target-title" onSubmit={submit} noValidate>
        <h2 id="add-target-title">Add WMI target</h2>
        <p className="sub" style={{ marginTop: 0 }}>
          Creates a WMI target in Turbonomic (<code>POST /api/v3/targets</code>) so it can discover Windows applications on the VMs in the scope.
        </p>

        {text('displayName', 'Display name', { type: 'text', autoComplete: 'off', maxLength: 128 })}
        {text('username', 'Username', { type: 'text', autoComplete: 'off', spellCheck: false })}
        {text('password', 'Password', { type: 'password', autoComplete: 'new-password' })}

        <div className="field">
          <label htmlFor="t-scope">Scope <span className="req">*</span></label>
          {scopes.loading ? (
            <div className="sub">Loading scopes from Turbonomic...</div>
          ) : scopes.error ? (
            <div className="notice bad" style={{ marginTop: 0 }}>
              {scopes.error} <button type="button" className="btn sm" onClick={loadScopes}>Retry</button>
            </div>
          ) : (
            <>
              <input type="text" placeholder="Filter scopes..." value={filter} onChange={(e) => setFilter(e.target.value)} aria-label="Filter scopes" style={{ marginBottom: 6 }} />
              <select
                id="t-scope"
                value={form.scope}
                onChange={set('scope')}
                onBlur={blur('scope')}
                className={err('scope') ? 'invalid' : ''}
                aria-invalid={!!err('scope')}
                aria-describedby={err('scope') ? 't-scope-err' : undefined}
                required
              >
                <option value="">Select a scope...</option>
                {visibleScopes.map((s) => (
                  <option key={s.uuid} value={s.uuid}>{s.name}{s.members != null ? ` (${s.members})` : ''} - {s.type}</option>
                ))}
              </select>
              {scopes.items.length === 0 && <div className="sub">No groups found in Turbonomic. Create a VM group first.</div>}
              {err('scope') && <div className="field-error" id="t-scope-err">{err('scope')}</div>}
              <div className="sub" style={{ marginTop: 4 }}>Turbonomic searches for Windows applications on the VMs in this scope (up to 500 VMs per target).</div>
            </>
          )}
        </div>

        <label className="check" htmlFor="t-ntlm">
          <input id="t-ntlm" type="checkbox" checked={form.useNtlm} onChange={set('useNtlm')} />
          <span>
            <strong>Use NTLM for domain accounts</strong>
            <span className="sub" style={{ display: 'block' }}>
              If you select this option, Turbonomic uses the NTLM protocol instead of the Kerberos protocol for domain accounts. NTLM is always used for local accounts.
            </span>
          </span>
        </label>

        {formError && <div className="notice bad" role="alert">{formError}</div>}

        <div className="modal-actions">
          <button type="button" className="btn" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="submit" className="btn primary" disabled={busy || scopes.loading || !!scopes.error}>
            {busy ? 'Adding...' : 'Add target'}
          </button>
        </div>
      </form>
    </div>
  );
}
