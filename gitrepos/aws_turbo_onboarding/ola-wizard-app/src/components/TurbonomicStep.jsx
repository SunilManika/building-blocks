import React, { useMemo, useRef, useState } from 'react';
import { api } from '../api.js';
import { validateTurbonomic, credentialFingerprint } from '../validation.js';
import PasswordInput from './PasswordInput.jsx';

export default function TurbonomicStep({ state, setState, next, verifiedFp, setVerifiedFp }) {
  const t = state.turbonomic;
  const [touched, setTouched] = useState({});
  const [submitted, setSubmitted] = useState(false);
  const [testing, setTesting] = useState(false);
  const [result, setResult] = useState(null); // { ok, message, errors }
  const [serverErrors, setServerErrors] = useState({});
  const lastServerFp = useRef(null);

  const local = useMemo(() => validateTurbonomic(t), [t]);
  const fp = credentialFingerprint(t);
  // Verified only for the exact host/username/password that passed; any edit invalidates it.
  const isVerified = verifiedFp === fp;

  // Server-reported field errors apply only to the values that produced them.
  const srv = lastServerFp.current === fp ? serverErrors : {};
  const errorFor = (f) => ((touched[f] || submitted) ? local.errors[f] : undefined) || srv[f];

  const set = (k) => (e) => {
    setState((s) => ({ ...s, turbonomic: { ...s.turbonomic, [k]: e.target.value } }));
    setResult(null);
  };
  const blur = (k) => () => setTouched((x) => ({ ...x, [k]: true }));

  const verify = async () => {
    setSubmitted(true);
    if (!local.valid) return;
    setTesting(true);
    setResult(null);
    const sent = fp;
    try {
      let r;
      try {
        r = await api.testTurbonomic(t);
      } catch (e) {
        r = { ok: false, message: e.data?.message || e.message, errors: e.data?.errors };
      }
      lastServerFp.current = sent;
      setResult(r);
      setServerErrors(r.ok ? {} : r.errors || {});
      setVerifiedFp(r.ok ? sent : null);
    } finally {
      setTesting(false);
    }
  };

  const field = (name, label, props) => {
    const err = errorFor(name);
    const Input = props.type === 'password' ? PasswordInput : 'input';
    return (
      <div className="field">
        <label htmlFor={`turbo-${name}`}>{label}</label>
        <Input
          id={`turbo-${name}`}
          className={err ? 'invalid' : ''}
          value={t[name]}
          onChange={set(name)}
          onBlur={blur(name)}
          aria-invalid={!!err}
          aria-describedby={err ? `turbo-${name}-err` : undefined}
          {...props}
        />
        {err && <div className="field-error" id={`turbo-${name}-err`}>{err}</div>}
      </div>
    );
  };

  return (
    <>
      <div className="card">
        <h2>1. Turbonomic instance</h2>
        <p className="lead">
          Enter the details of the provisioned Turbonomic instance. These are written to <code>turbonomic</code> in{' '}
          <code>config/config.json</code>. Click <strong>Test connection</strong>; <strong>Save &amp; continue</strong> stays
          disabled until the credentials are verified against the host.
        </p>
        {field('host', <>Host (e.g. <code>customer.turbonomic.ibm.com</code>)</>, {
          type: 'text', placeholder: 'https://tenant.turbonomic.ibmappdomain.cloud/', autoComplete: 'off', spellCheck: false,
        })}
        <div className="row">
          {field('username', 'Admin username', { type: 'text', autoComplete: 'off' })}
          {field('password', 'Admin password', { type: 'password', autoComplete: 'new-password' })}
        </div>
        <button className="btn" onClick={verify} disabled={testing || !local.valid}>
          {testing ? 'Verifying...' : 'Test connection'}
        </button>
        {!local.valid && (touched.host || touched.username || touched.password || submitted) && (
          <span className="sub" style={{ marginLeft: 12 }}>Complete the required fields to test.</span>
        )}
        {result && <div className={`notice ${result.ok ? 'ok' : 'bad'}`} role="status">{result.message}</div>}
        {isVerified && !result && <div className="notice ok">Credentials verified for these values.</div>}
      </div>
      <div className="nav">
        <button className="btn" disabled>Back</button>
        <button
          className="btn primary"
          onClick={next}
          disabled={!isVerified || testing}
          title={isVerified ? '' : 'Verify the credentials with Test connection first'}
        >
          Save &amp; continue
        </button>
      </div>
    </>
  );
}
