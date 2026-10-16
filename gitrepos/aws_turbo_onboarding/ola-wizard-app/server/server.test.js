import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { RunManager } from './runs.js';
import { validateConfig } from './configValidate.js';

// ---------------------------------------------------------------- runs
function fakeChild() {
  const c = new EventEmitter();
  c.stdout = new EventEmitter(); c.stderr = new EventEmitter(); c.pid = 0;
  return c;
}
const manager = (over = {}) => {
  const children = [];
  const m = new RunManager({ cwd: '.', isWin: true, spawn: () => { const c = fakeChild(); children.push(c); return c; }, ...over });
  m.kill = (run) => { run.child?.emit('close', null, 'SIGTERM'); }; // no real processes in unit tests
  return { m, children };
};

test('only one run at a time', () => {
  const { m, children } = manager();
  const r1 = m.start('report', 'pwsh', ['-File', 'x']);
  assert.equal(r1.status, 'running');
  assert.ok(m.start('report', 'pwsh', []).busy);
  children[0].emit('close', 0, null);
  assert.equal(r1.status, 'succeeded');
  assert.equal(m.start('report', 'pwsh', []).status, 'running');
  m.stopAll();
});

test('exit codes map to succeeded / failed, spawn errors to failed', () => {
  const { m, children } = manager();
  const a = m.start('report', 'x', []); children[0].emit('close', 3, null);
  assert.equal(a.status, 'failed'); assert.equal(a.exitCode, 3);
  const b = m.start('report', 'x', []); children[1].emit('error', new Error('ENOENT'));
  assert.equal(b.status, 'failed'); assert.match(m.read(b.id).output, /ENOENT/);
  const throwing = new RunManager({ cwd: '.', spawn: () => { throw new Error('boom'); } });
  assert.equal(throwing.start('report', 'x', []).status, 'failed');
});

test('cancel marks the run cancelled, not failed', () => {
  const { m } = manager();
  const r = m.start('report', 'x', []);
  m.cancel(r.id);
  assert.equal(r.status, 'cancelled');
  assert.equal(m.cancel('nope'), null);
});

test('timeout stops the run and reports failed + timedOut', async () => {
  const { m } = manager({ timeoutMs: 20 });
  const r = m.start('report', 'x', []);
  await new Promise((res) => setTimeout(res, 60));
  assert.equal(r.status, 'failed'); assert.equal(r.timedOut, true);
  assert.match(m.read(r.id).output, /exceeded/);
});

test('output is capped and offsets stay consistent', () => {
  const { m, children } = manager({ maxOutputBytes: 100 });
  const r = m.start('report', 'x', []);
  let polled = '';
  let offset = 0;
  for (let i = 0; i < 50; i += 1) {
    children[0].stdout.emit('data', Buffer.from(`line-${String(i).padStart(3, '0')}\n`));
    const p = m.read(r.id, offset);
    polled += p.output; offset = p.offset;
  }
  assert.ok(r.bytes <= 100 + 9);
  const full = m.read(r.id, 0);
  assert.equal(full.truncated, true);
  assert.ok(polled.endsWith('line-049\n'));
  assert.ok(polled.startsWith('line-000'));   // a poller that kept up lost nothing
  m.stopAll();
});

test('finished runs are pruned after the retention period', () => {
  let t = 0;
  const { m, children } = manager({ retainMs: 100, now: () => t });
  const r = m.start('report', 'x', []); children[0].emit('close', 0, null);
  t += 101; m.prune();
  assert.equal(m.read(r.id), null);
});

// ---------------------------------------------------------------- config validation
const good = () => ({
  turbonomic: { host: 'tz1.demo.turbonomic.com', admin_username: 'u', admin_password: 'p' },
  targets: {
    windows: [{ vm_name: 'win1', nameOrAddress: '10.0.0.5', username: 'turbowmid16', password: 'pw', domain: 'WORKGROUP' }],
    linux: [{ vm_name: 'lin1', nameOrAddress: 'lin1.corp.local', username: 'root', password: '', ssh_key_file: 'C:\\keys\\id_rsa' }],
  },
});

test('a normal config is valid', () => assert.deepEqual(validateConfig(good()), { valid: true, errors: [] }));

test('config validation rejects bad shapes and values', () => {
  const bad = (mut, re) => { const c = good(); mut(c); const r = validateConfig(c); assert.equal(r.valid, false, String(re)); assert.match(r.errors.join('|'), re); };
  for (const x of [null, [], 'x', 5]) assert.equal(validateConfig(x).valid, false);
  bad((c) => { c.turbonomic.host = 'http://x'; }, /HTTPS/);
  bad((c) => { c.turbonomic.admin_password = ''; }, /admin_password is required/);
  bad((c) => { c.targets.windows[0].nameOrAddress = '10.0.0.999'; }, /not a valid/);
  bad((c) => { c.targets.windows[0].nameOrAddress = 'a b'; }, /only an IP/);
  bad((c) => { c.targets.windows[0].username = 'DOM\\bob'; }, /domain/);
  bad((c) => { c.targets.windows[0].vm_name = 'a\nb'; }, /control/);
  bad((c) => { c.targets.windows[0].domain = ''; }, /domain/);
  bad((c) => { c.targets.windows.push({ ...c.targets.windows[0], nameOrAddress: '10.0.0.6' }); }, /VM name/);
  bad((c) => { c.targets.windows.push({ ...c.targets.windows[0], vm_name: 'other' }); }, /Address/);
  bad((c) => { c.targets.linux[0].ssh_key_file = ''; }, /password or an SSH key/);
  bad((c) => { c.targets.linux[0].ssh_key_file = 'C:\\keys\\..\\x'; }, /\.\./);
  bad((c) => { c.targets.windows = 'nope'; }, /must be a list/);
  bad((c) => { c.targets.windows[0] = 'str'; }, /must be an object/);
  bad((c) => { c.discovery = 5; }, /discovery/);
});

test('config validation caps the number of VMs', () => {
  const c = good();
  c.targets.windows = Array.from({ length: 501 }, (_, i) => ({ vm_name: `v${i}`, nameOrAddress: `10.0.${Math.floor(i / 250)}.${i % 250 + 1}`, username: 'u', password: 'p', domain: 'WORKGROUP' }));
  assert.match(validateConfig(c).errors.join('|'), /At most 500/);
});
