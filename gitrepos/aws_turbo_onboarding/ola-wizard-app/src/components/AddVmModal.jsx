import React, { useEffect, useMemo, useRef, useState } from 'react';
import { emptyVm, validateVm } from '../validation.js';
import PasswordInput from './PasswordInput.jsx';

// Add/Edit popup for one VM. `initial` is null when adding; `otherNames` are the other VMs' names;
// `vmChoices` are the VM names that can be picked (used for scope-locked Windows add);
// `fixedOs` (e.g. 'Linux') pre-selects and locks the OS field.
// When fixedOs='Linux' and initial=null (adding), the VM name is a free-text input.
export default function AddVmModal({ initial, otherNames, vmChoices, fixedOs, onClose, onSave }) {
  const isAddingLinux = fixedOs === 'Linux' && !initial;

  const [form, setForm] = useState(initial || { ...emptyVm(), ...(fixedOs ? { os: fixedOs } : {}) });
  const [touched, setTouched] = useState({});
  const [submitted, setSubmitted] = useState(false);
  // 'password' | 'key' — controls which SSH auth field is shown
  const [sshAuthMode, setSshAuthMode] = useState(() => {
    if (initial?.ssh_key_file) return 'key';
    return 'password';
  });
  const firstField = useRef(null);

  const { valid, errors } = useMemo(() => validateVm(form, otherNames), [form, otherNames]);
  const err = (f) => ((touched[f] || submitted) ? errors[f] : undefined);

  useEffect(() => {
    firstField.current?.focus();
    const onKey = (e) => { if (e.key === 'Escape') onClose(); };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }));
  const blur = (k) => () => setTouched((t) => ({ ...t, [k]: true }));

  // When the auth mode toggle changes, clear the field that is being hidden so
  // validation doesn't complain about a field the user can no longer see.
  const switchSshMode = (mode) => {
    setSshAuthMode(mode);
    if (mode === 'key') setForm((f) => ({ ...f, ssh_password: '' }));
    else setForm((f) => ({ ...f, ssh_key_file: '' }));
  };

  const submit = (e) => {
    e.preventDefault();
    setSubmitted(true);
    if (!valid) return;
    onSave({
      ...form,
      vm_name: form.vm_name.trim(),
      address: form.address.trim(),
      domain: form.domain.trim(),
      ssh_key_file: form.ssh_key_file.trim(),
    });
  };

  const field = (name, label, { required = true, hint, ...props } = {}) => {
    const Input = props.type === 'password' ? PasswordInput : 'input';
    return (
      <div className="field">
        <label htmlFor={`vm-${name}`}>{label} {required && <span className="req">*</span>}</label>
        <Input
          id={`vm-${name}`}
          ref={name === 'vm_name' ? firstField : undefined}
          value={form[name]}
          onChange={set(name)}
          onBlur={blur(name)}
          className={err(name) ? 'invalid' : ''}
          aria-invalid={!!err(name)}
          aria-describedby={err(name) ? `vm-${name}-err` : undefined}
          {...props}
        />
        {hint && <div className="sub" style={{ marginTop: 4 }}>{hint}</div>}
        {err(name) && <div className="field-error" id={`vm-${name}-err`}>{err(name)}</div>}
      </div>
    );
  };

  const isWin = form.os === 'Windows';

  return (
    <div className="modal-backdrop" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <form className="modal" role="dialog" aria-modal="true" aria-labelledby="add-vm-title" onSubmit={submit} noValidate>
        <h2 id="add-vm-title">{initial ? 'Edit VM' : (isAddingLinux ? 'Add Linux VM' : 'Add VM')}</h2>

        {/* VM name — free-text input for manual Linux add; dropdown for scope-locked add/edit */}
        {isAddingLinux ? (
          field('vm_name', 'VM name', {
            type: 'text',
            autoComplete: 'off',
            spellCheck: false,
            hint: 'Enter the VM name exactly as it appears in Turbonomic (or any identifier you choose).',
          })
        ) : (
          <div className="field">
            <label htmlFor="vm-vm_name">VM name <span className="req">*</span></label>
            <select
              id="vm-vm_name"
              ref={firstField}
              value={form.vm_name}
              onChange={set('vm_name')}
              onBlur={blur('vm_name')}
              className={err('vm_name') ? 'invalid' : ''}
              aria-invalid={!!err('vm_name')}
              aria-describedby={err('vm_name') ? 'vm-vm_name-err' : undefined}
            >
              <option value="">{fixedOs ? `Select a ${fixedOs} VM...` : 'Select a VM from the target...'}</option>
              {vmChoices.map((n) => <option key={n} value={n}>{n}</option>)}
            </select>
            <div className="sub" style={{ marginTop: 4 }}>
              {fixedOs ? `${fixedOs} VMs found by the Turbonomic search API.` : 'Only VMs in the target scope from step 2 can be added.'}
            </div>
            {err('vm_name') && <div className="field-error" id="vm-vm_name-err">{err('vm_name')}</div>}
          </div>
        )}

        <div className="row">
          {field('address', 'IP / hostname', { type: 'text', autoComplete: 'off', spellCheck: false })}
          <div className="field">
            <label htmlFor="vm-os">OS <span className="req">*</span></label>
            <select id="vm-os" value={form.os} onChange={set('os')} disabled={!!fixedOs}>
              <option>Windows</option>
              <option>Linux</option>
            </select>
          </div>
        </div>

        {isWin ? (
          field('domain', 'Domain (or WORKGROUP)', { type: 'text', autoComplete: 'off', spellCheck: false })
        ) : (
          <>
            {field('ssh_username', 'SSH username', { type: 'text', autoComplete: 'off', spellCheck: false })}

            {/* Auth mode toggle */}
            <div className="field">
              <label>SSH authentication <span className="req">*</span></label>
              <div className="auth-mode">
                <button
                  type="button"
                  className={`auth-mode-btn${sshAuthMode === 'password' ? ' active' : ''}`}
                  onClick={() => switchSshMode('password')}
                  aria-pressed={sshAuthMode === 'password'}
                >
                  Password
                </button>
                <button
                  type="button"
                  className={`auth-mode-btn${sshAuthMode === 'key' ? ' active' : ''}`}
                  onClick={() => switchSshMode('key')}
                  aria-pressed={sshAuthMode === 'key'}
                >
                  SSH key file
                </button>
              </div>
            </div>

            {sshAuthMode === 'password' ? (
              <div className="field">
                <label htmlFor="vm-ssh_password">Password <span className="req">*</span></label>
                <PasswordInput
                  id="vm-ssh_password"
                  value={form.ssh_password}
                  onChange={set('ssh_password')}
                  onBlur={blur('ssh_password')}
                  autoComplete="new-password"
                  className={err('ssh_password') ? 'invalid' : ''}
                  aria-invalid={!!err('ssh_password')}
                  aria-describedby={err('ssh_password') ? 'vm-ssh_password-err' : undefined}
                />
                {err('ssh_password') && <div className="field-error" id="vm-ssh_password-err">{err('ssh_password')}</div>}
              </div>
            ) : (
              <div className="field">
                <label htmlFor="vm-ssh_key_file">Private key path (inside the container) <span className="req">*</span></label>
                <input
                  id="vm-ssh_key_file"
                  type="text"
                  value={form.ssh_key_file}
                  onChange={set('ssh_key_file')}
                  onBlur={blur('ssh_key_file')}
                  spellCheck={false}
                  placeholder="C:\keys\id_ed25519"
                  className={err('ssh_key_file') ? 'invalid' : ''}
                  aria-invalid={!!err('ssh_key_file')}
                  aria-describedby={err('ssh_key_file') ? 'vm-ssh_key_file-err' : undefined}
                />
                <div className="sub" style={{ marginTop: 4 }}>
                  Place the key file in the <code>keys</code> folder next to <code>docker-compose.yml</code>;
                  it is mounted at <code>C:\keys</code> inside the container.
                </div>
                {err('ssh_key_file') && <div className="field-error" id="vm-ssh_key_file-err">{err('ssh_key_file')}</div>}
              </div>
            )}
          </>
        )}

        <div className="modal-actions">
          <button type="button" className="btn" onClick={onClose}>Cancel</button>
          <button type="submit" className="btn primary">
            {initial ? 'Save VM' : (isAddingLinux ? 'Add Linux VM' : 'Add VM')}
          </button>
        </div>
      </form>
    </div>
  );
}
