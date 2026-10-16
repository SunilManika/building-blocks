import React from 'react';

const STEPS = [
  { name: 'Turbonomic', desc: 'Verify instance credentials' },
  { name: 'Targets', desc: 'Add WMI targets' },
  { name: 'VMs inventory', desc: 'Describe the target VMs' },
  { name: 'Review', desc: 'Confirm the VMs' },
  { name: 'Run', desc: 'Collect and report' },
];

// Home page banner shown above the Prerequisites.
export default function Hero() {
  return (
    <>
      <section className="hero">
        <p className="eyebrow">IBM Turbonomic &middot; AWS migration assessment</p>
        <h2>AWS OLA Onboarding Wizard</h2>
        <p>
          Connect to Turbonomic, register Guest OS targets, describe your VMs and run the toolkit to produce the
          assessment data used to plan your move to AWS.
        </p>
      </section>
      <div className="steps-grid" aria-label="Wizard steps">
        {STEPS.map((s, i) => (
          <div className="step-tile" key={s.name}>
            <div className="num">{String(i + 1).padStart(2, '0')}</div>
            <div className="name">{s.name}</div>
            <div className="desc">{s.desc}</div>
          </div>
        ))}
      </div>
    </>
  );
}
