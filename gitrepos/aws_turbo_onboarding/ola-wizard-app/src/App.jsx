import React, { useEffect, useState } from 'react';
import { api } from './api.js';
import { emptyState, stateFromConfig } from './configModel.js';
import { credentialFingerprint } from './validation.js';
import Prerequisites from './components/Prerequisites.jsx';
import TurbonomicStep from './components/TurbonomicStep.jsx';
import TargetsStep from './components/TargetsStep.jsx';
import VmsStep from './components/VmsStep.jsx';
import ReviewStep from './components/ReviewStep.jsx';
import RunStep from './components/RunStep.jsx';
import Hero from './components/Hero.jsx';

const TABS = ['Prerequisites', '1. Turbonomic', '2. Targets', '3. VMs inventory', '4. Review', '5. Run'];

export default function App() {
  const [tab, setTab] = useState(0);
  const [maxTab, setMaxTab] = useState(0);
  const [state, setState] = useState(emptyState);
  const [existing, setExisting] = useState(null);
  const [saved, setSaved] = useState(false);
  const [verifiedFp, setVerifiedFp] = useState(null); // fingerprint of the credentials that passed Test connection
  const [addedTargets, setAddedTargets] = useState([]); // WMI targets created in Turbonomic during this session
  const [loadError, setLoadError] = useState(''); // why the saved config could not be pre-filled
  const [removedVms, setRemovedVms] = useState([]); // lower-case names of Windows VMs the user removed in step 3

  // Everything after step 1 is only reachable while the current credentials are the verified ones.
  const credsVerified = verifiedFp !== null && verifiedFp === credentialFingerprint(state.turbonomic);
  useEffect(() => {
    if (!credsVerified && tab > 1) setTab(1);
  }, [credsVerified, tab]);

  // Pre-fill from an existing config/config.json when present (re-run when the toolkit folder changes).
  const loadConfig = () => {
    api.getConfig()
      .then((r) => {
        setLoadError(r.error || '');
        if (r.config) {
          setExisting(r.config);
          setState(stateFromConfig(r.config));
        }
      })
      .catch((e) => setLoadError(`Could not load the saved configuration: ${e.message}`));
  };
  useEffect(loadConfig, []);

  const go = (i) => { setTab(i); setMaxTab((m) => Math.max(m, i)); };
  const next = () => go(tab + 1);
  const back = () => setTab(tab - 1);
  const common = { state, setState, next, back };
  const locked = (i) => i > maxTab || (i > 1 && !credsVerified);

  return (
    <div className="shell">
      <div className="main">
        <header className="header">
          <h1><span className="brand">AWS</span> OLA Onboarding Wizard</h1>
          <span className="tagline">Turbonomic assessment for AWS migration</span>
        </header>
        <div className="container">
          {loadError && (
            <div className="notice warn" role="alert" style={{ marginTop: 0, marginBottom: 16 }}>
              {loadError} <button className="btn sm" onClick={loadConfig}>Retry</button>
            </div>
          )}
          {tab === 0 && <Hero />}
          <nav className="tabs">
            {TABS.map((t, i) => (
              <button
                key={t}
                className={`tab ${i === tab ? 'active' : ''} ${i < tab ? 'done' : ''}`}
                onClick={() => !locked(i) && setTab(i)}
                disabled={locked(i)}
                title={i > 1 && !credsVerified ? 'Verify the Turbonomic credentials in step 1 first' : ''}
              >
                {t}
              </button>
            ))}
          </nav>
          {tab === 0 && (
            <>
              <Prerequisites />
              <div className="nav"><span /><button className="btn primary" onClick={next}>Continue</button></div>
            </>
          )}
          {tab === 1 && <TurbonomicStep {...common} verifiedFp={verifiedFp} setVerifiedFp={setVerifiedFp} />}
          {tab === 2 && <TargetsStep {...common} addedTargets={addedTargets} setAddedTargets={setAddedTargets} />}
          {tab === 3 && <VmsStep {...common} addedTargets={addedTargets} removedVms={removedVms} setRemovedVms={setRemovedVms} />}
          {tab === 4 && <ReviewStep {...common} existing={existing} setSaved={setSaved} />}
          {tab === 5 && <RunStep saved={saved} back={back} />}
        </div>
      </div>
    </div>
  );
}
