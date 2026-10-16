// OLA Onboarding Wizard - API + static host.
// Intended to run in the Windows container (see Dockerfile) that holds the Turbonomic toolkit.
import express from 'express';
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import { validateTurbonomic, validateWmiTarget } from '../src/validation.js';
import { REPORT_CSP, installApiGuards, securityHeaders } from './security.js';
import { RunManager } from './runs.js';
import { validateConfig } from './configValidate.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const APP_ROOT = path.resolve(__dirname, '..');
// Toolkit root = folder that contains config/, target-setup/, Invoke-FleetReport.ps1.
// In the container it is fixed by OLA_TOOLKIT_ROOT (C:\toolkit); outside Docker it defaults to the parent of the app.
const ROOT = process.env.OLA_TOOLKIT_ROOT
  ? path.resolve(process.env.OLA_TOOLKIT_ROOT)
  : path.resolve(APP_ROOT, '..');
const CONFIG_PATH = path.join(ROOT, 'config', 'config.json');
const OUTPUT_DIR = path.join(ROOT, 'output');
const IS_WIN = process.platform === 'win32';

// ---------------------------------------------------------------- settings (environment)
const envBool = (v) => ['1', 'true', 'yes', 'on'].includes(String(v || '').toLowerCase());
const envInt = (name, def, min, max) => {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return def;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < min || n > max) {
    console.error(`${name} must be a whole number from ${min} to ${max}.`);
    process.exit(1);
  }
  return n;
};
const PORT = envInt('PORT', 5050, 1, 65535);
// Loopback by default; the container sets HOST=0.0.0.0 so the published port is reachable.
const HOST = process.env.HOST || '127.0.0.1';
const loopback = (h) => ['127.0.0.1', 'localhost', '::1'].includes(h);
const TLS = process.env.OLA_TLS_CERT && process.env.OLA_TLS_KEY ? { cert: process.env.OLA_TLS_CERT, key: process.env.OLA_TLS_KEY } : null;
const TRUST_PROXY = envBool(process.env.OLA_TRUST_PROXY);
const secureCookies = Boolean(TLS);
// false = accept self-signed certificates from Turbonomic (the toolkit's default); true = verify them.
const TURBO_VERIFY_TLS = envBool(process.env.OLA_TURBONOMIC_VERIFY_TLS);
const RUN_TIMEOUT_MS = envInt('OLA_RUN_TIMEOUT_MINUTES', 120, 1, 1440) * 60_000;
const ALLOWED_ORIGINS = (process.env.OLA_ALLOWED_ORIGINS || '').split(',').map((s) => s.trim()).filter(Boolean);

// One JSON line per important event (config save, run start/cancel) for the container log.
function audit(event, req, extra = {}) {
  console.log(JSON.stringify({ ts: new Date().toISOString(), event, ip: req?.ip, ...extra }));
}

const app = express();
app.disable('x-powered-by');
app.set('trust proxy', TRUST_PROXY);
app.use(securityHeaders({ secureCookies }));
app.use(express.json({ limit: '1mb', strict: true }));
installApiGuards(app, { allowedOrigins: ALLOWED_ORIGINS });

// ---------------------------------------------------------------- helpers
function tryRun(cmd, args, timeout = 15000) {
  try {
    const r = spawnSync(cmd, args, { encoding: 'utf8', timeout, windowsHide: true });
    if (r.error || r.status !== 0) return null;
    return `${r.stdout || ''}${r.stderr || ''}`.trim();
  } catch {
    return null;
  }
}

function findPython() {
  const candidates = IS_WIN ? [['py', ['-3']], ['python', []], ['python3', []]] : [['python3', []], ['python', []]];
  for (const [cmd, pre] of candidates) {
    const out = tryRun(cmd, [...pre, '--version']);
    if (out && /Python 3/.test(out)) return { cmd, pre, version: out.replace('Python ', '') };
  }
  return null;
}

function findPowerShell() {
  const pwsh = tryRun('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()']);
  if (pwsh) return { cmd: 'pwsh', version: pwsh, major: 7 };
  if (IS_WIN) {
    const ps = tryRun('powershell.exe', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()']);
    if (ps) return { cmd: 'powershell.exe', version: ps, major: Number(ps.split('.')[0]) };
  }
  return null;
}

function readConfig() {
  if (!fs.existsSync(CONFIG_PATH)) return null;
  return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8').replace(/^\uFEFF/, ''));
}

// A shared agent keeps connections to Turbonomic alive across the many calls one wizard action makes.
const turboAgent = new https.Agent({ keepAlive: true, maxSockets: 8, rejectUnauthorized: TURBO_VERIFY_TLS });
const MAX_TURBO_RESPONSE = 32 * 1024 * 1024;

// ---------------------------------------------------------------- Turbonomic credential validation
// Flow: validate input -> POST /api/v3/login (form-encoded, as the toolkit does) -> GET /api/v3/users/me with the
// returned session cookie -> confirm the account is who we asked for and can administer targets.
// ADMINISTRATOR is the full admin; SITE_ADMIN ("Site administrator") can administer Target configuration and is the
// highest role customers get on Turbonomic SaaS (ADMINISTRATOR is reserved for the IBM representative).
const TARGET_ADMIN_ROLES = new Set(['ADMINISTRATOR', 'SITE_ADMIN', 'SITE_ADMINISTRATOR']);
function turboCall({ host, port, method, path: urlPath, headers = {}, body }) {
  return new Promise((resolve, reject) => {
    // Turbonomic appliances commonly use self-signed certs, so verification is off unless OLA_TURBONOMIC_VERIFY_TLS=true.
    const req = https.request(
      {
        host, port, method, path: urlPath, agent: turboAgent,
        timeout: 20000,
        headers: { Accept: 'application/json', ...headers, ...(body ? { 'Content-Length': Buffer.byteLength(body) } : {}) },
      },
      (r) => {
        const chunks = [];
        let size = 0;
        r.on('data', (c) => {
          size += c.length;
          if (size > MAX_TURBO_RESPONSE) return req.destroy(Object.assign(new Error('response too large'), { code: 'EMSGSIZE' }));
          chunks.push(c);
        });
        r.on('error', reject);
        r.on('aborted', () => reject(Object.assign(new Error('connection closed early'), { code: 'ECONNRESET' })));
        r.on('end', () => resolve({ status: r.statusCode, headers: r.headers, text: Buffer.concat(chunks).toString('utf8') }));
      }
    );
    req.on('timeout', () => req.destroy(Object.assign(new Error('timed out'), { code: 'ETIMEDOUT' })));
    req.on('error', reject);
    req.end(body);
  });
}

function networkMessage(e, target) {
  const where = `${target.host}:${target.port}`;
  switch (e.code) {
    case 'ENOTFOUND': case 'EAI_AGAIN': return `Host "${target.host}" could not be resolved. Check the spelling and DNS.`;
    case 'ECONNREFUSED': return `Connection refused by ${where}. Check the host and port.`;
    case 'ETIMEDOUT': case 'ECONNRESET': return `No response from ${where}. Check the host, firewall and VPN.`;
    case 'EHOSTUNREACH': case 'ENETUNREACH': return `${where} is unreachable from this machine.`;
    case 'EMSGSIZE': return `${where} returned more data than the wizard accepts.`;
    case 'CERT_HAS_EXPIRED': case 'DEPTH_ZERO_SELF_SIGNED_CERT': case 'SELF_SIGNED_CERT_IN_CHAIN': case 'UNABLE_TO_VERIFY_LEAF_SIGNATURE':
      return `${where} presented a certificate that is not trusted (${e.code}). Install its CA, or leave OLA_TURBONOMIC_VERIFY_TLS off.`;
    default: return `Could not connect to ${where}: ${e.message}`;
  }
}

const tryJson = (t) => { try { return JSON.parse(t); } catch { return null; } };
// Logs in and returns a verified admin session, or { ok:false, status, body } describing why not.
// Used by every Turbonomic route so credentials are always re-checked server-side.
async function openSession(input) {
  const { username = '', password = '' } = input || {};
  const v = validateTurbonomic({ host: input?.host, username, password });
  if (!v.valid) return { ok: false, status: 400, body: { ok: false, stage: 'input', errors: v.errors, message: 'Fix the highlighted fields.' } };
  const target = v.target;
  // The wizard must not be usable to probe loopback, link-local (cloud metadata) or multicast addresses.
  if (/^(169\.254\.|0\.|127\.|22[4-9]\.|23\d\.|24\d\.|25[0-5]\.)/.test(target.host) || /^(localhost|metadata\.google\.internal)$/i.test(target.host)) {
    return { ok: false, status: 400, body: { ok: false, stage: 'input', errors: { host: 'This address cannot be a Turbonomic server.' }, message: 'Fix the highlighted fields.' } };
  }
  const fail = (stage, message, extra = {}) => ({ ok: false, status: 200, body: { ok: false, stage, message, ...extra } });

  try {
    const body = new URLSearchParams({ username, password }).toString();
    const login = await turboCall({
      ...target, method: 'POST', path: '/api/v3/login', body,
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    });

    if (login.status === 401 || login.status === 403) {
      return fail('login', 'Turbonomic rejected the username or password.', { errors: { password: 'Invalid username or password.' } });
    }
    if (login.status === 404) {
      return fail('login', `${target.host} responded, but it does not look like a Turbonomic server (/api/v3/login not found). Check the host.`, { errors: { host: 'Not a Turbonomic API endpoint.' } });
    }
    if (login.status === 429) return fail('login', 'Too many login attempts. Wait a minute and try again.');
    if (login.status >= 500) return fail('login', `Turbonomic returned HTTP ${login.status}. The instance may be starting up or unavailable.`);
    if (login.status !== 200 && login.status !== 204) return fail('login', `Unexpected response from Turbonomic: HTTP ${login.status}.`);

    const cookies = (login.headers['set-cookie'] || []).map((c) => c.split(';')[0]);
    if (!cookies.length) {
      return fail('login', 'The server answered but did not issue a session, so this does not look like a Turbonomic login. Check the host.', { errors: { host: 'No Turbonomic session returned.' } });
    }
    const cookie = cookies.join('; ');

    const me = await turboCall({ ...target, method: 'GET', path: '/api/v3/users/me', headers: { Cookie: cookie } });
    if (me.status === 401 || me.status === 403) return fail('session', 'Login succeeded but the session was not accepted for API calls.');
    if (me.status !== 200) return fail('session', `Logged in, but verifying the account failed (HTTP ${me.status}).`);

    const user = tryJson(me.text);
    if (!user || typeof user !== 'object') return fail('session', 'Logged in, but the account details response was not valid JSON.');

    const actual = user.username || user.displayName || username;
    const roles = [user.roleName, ...(Array.isArray(user.roles) ? user.roles.map((r) => r.name) : [])].filter(Boolean);
    if (user.username && user.username.toLowerCase() !== username.trim().toLowerCase()) {
      return fail('session', `Session belongs to "${user.username}", not "${username}".`);
    }
    if (!roles.some((r) => TARGET_ADMIN_ROLES.has(String(r).trim().toUpperCase().replace(/[\s-]+/g, '_')))) {
      return fail('role', `Credentials are valid for "${actual}", but the account role (${roles.join(', ') || 'unknown'}) cannot manage targets. Use an account with the Administrator or Site administrator role.`, { user: actual, roles });
    }
    return { ok: true, target, cookie, user: actual, roles };
  } catch (e) {
    return fail('network', networkMessage(e, target), { errors: { host: 'Host unreachable.' } });
  }
}

app.post('/api/turbonomic/test', async (req, res) => {
  const s = await openSession(req.body);
  if (!s.ok) return res.status(s.status).json(s.body);
  res.json({ ok: true, stage: 'done', message: `Credentials verified against ${s.target.host}. Signed in as ${s.user} (${s.roles.join(', ')}).`, user: s.user, roles: s.roles });
});

// Scopes a WMI target can use: Turbonomic groups (VM groups, clusters, ...). GET /api/v3/groups is paginated
// with limit + x-next-cursor.
app.post('/api/turbonomic/scopes', async (req, res) => {
  const s = await openSession(req.body);
  if (!s.ok) return res.status(s.status).json(s.body);
  try {
    const scopes = [];
    let cursor = '';
    for (let page = 0; page < 40; page += 1) {
      const qs = new URLSearchParams({ limit: '500', ...(cursor ? { cursor } : {}) });
      const r = await turboCall({ ...s.target, method: 'GET', path: `/api/v3/groups?${qs}`, headers: { Cookie: s.cookie } });
      if (r.status !== 200) {
        return res.json({ ok: false, stage: 'scopes', message: `Could not list scopes from Turbonomic (HTTP ${r.status}).` });
      }
      const items = tryJson(r.text);
      if (!Array.isArray(items)) return res.json({ ok: false, stage: 'scopes', message: 'Turbonomic returned an unexpected scope list.' });
      for (const g of items) {
        if (g?.uuid && g?.displayName) {
          scopes.push({ uuid: g.uuid, name: g.displayName, type: g.groupType || g.className || 'Group', members: g.membersCount ?? g.entitiesCount ?? null });
        }
      }
      cursor = r.headers['x-next-cursor'] || '';
      if (!cursor) break;
    }
    scopes.sort((a, b) => a.name.localeCompare(b.name));
    res.json({ ok: true, scopes });
  } catch (e) {
    res.json({ ok: false, stage: 'network', message: networkMessage(e, s.target) });
  }
});

// Creates a WMI target: POST /api/v3/targets with category "Guest OS Processes", type "WMI" and the inputFields
// the toolkit's build_wmi_target_dto() uses (targetEntities, targetId, username, password, useNTLM, ...).
app.post('/api/turbonomic/targets', async (req, res) => {
  const t = req.body?.target || {};
  const tv = validateWmiTarget(t);
  if (!tv.valid) return res.status(400).json({ ok: false, stage: 'input', errors: tv.errors, message: 'Fix the highlighted fields.' });

  const s = await openSession(req.body?.turbonomic);
  if (!s.ok) return res.status(s.status).json({ ...s.body, stage: s.body.stage === 'input' ? 'turbonomic' : s.body.stage });

  const headers = { Cookie: s.cookie, 'Content-Type': 'application/json' };
  const displayName = t.displayName.trim();
  try {
    // Refuse to create a duplicate display name.
    const list = await turboCall({ ...s.target, method: 'GET', path: '/api/v3/targets', headers });
    if (list.status === 200) {
      const existing = (tryJson(list.text) || []).find((x) => {
        if ((x.type || '').toUpperCase() !== 'WMI') return false;
        const id = (x.inputFields || []).find((f) => f.name === 'targetId')?.value;
        return [x.displayName, id].some((n) => typeof n === 'string' && n.toLowerCase() === displayName.toLowerCase());
      });
      if (existing) {
        return res.status(409).json({ ok: false, stage: 'duplicate', errors: { displayName: 'A WMI target with this display name already exists.' }, message: `A WMI target named "${displayName}" already exists in Turbonomic.` });
      }
    }

    const dto = {
      category: 'Guest OS Processes',
      type: 'WMI',
      displayName,
      inputFields: [
        { name: 'targetEntities', value: t.scope },
        { name: 'targetId', value: displayName },
        { name: 'username', value: t.username },
        { name: 'password', value: t.password },
        { name: 'domainName', value: '' },
        { name: 'useNTLM', value: String(!!t.useNtlm) },
        { name: 'secure', value: 'false' },
        { name: 'fullValidation', value: 'false' },
      ],
    };
    const body = JSON.stringify(dto);
    const r = await turboCall({ ...s.target, method: 'POST', path: '/api/v3/targets', headers, body });
    const out = tryJson(r.text);
    if (r.status >= 200 && r.status < 300) {
      return res.json({ ok: true, uuid: out?.uuid || '', status: out?.status || 'Created', message: `WMI target "${displayName}" was added to Turbonomic.` });
    }
    const detail = (out && (out.message || out.error)) || (r.text || '').slice(0, 300);
    if (r.status === 400 || r.status === 500) {
      return res.json({ ok: false, stage: 'create', message: `Turbonomic could not add the target (HTTP ${r.status}).${detail ? ` ${String(detail).replace(/[.\s]*$/, '.')}` : ''} Check the scope, username and password.` });
    }
    if (r.status === 401 || r.status === 403) return res.json({ ok: false, stage: 'create', message: 'Turbonomic denied permission to add targets.' });
    return res.json({ ok: false, stage: 'create', message: `Unexpected response adding the target: HTTP ${r.status}. ${detail}` });
  } catch (e) {
    res.json({ ok: false, stage: 'network', message: networkMessage(e, s.target) });
  }
});

// Current status of previously added targets, from one GET /api/v3/targets call.
app.post('/api/turbonomic/targets/status', async (req, res) => {
  const uuids = req.body?.uuids;
  if (!Array.isArray(uuids) || uuids.length === 0 || uuids.length > 200 || !uuids.every((u) => typeof u === 'string' && u)) {
    return res.status(400).json({ ok: false, message: 'Provide 1-200 target uuids.' });
  }
  const s = await openSession(req.body?.turbonomic);
  if (!s.ok) return res.status(s.status).json(s.body);
  try {
    const r = await turboCall({ ...s.target, method: 'GET', path: '/api/v3/targets', headers: { Cookie: s.cookie } });
    if (r.status !== 200) return res.json({ ok: false, message: `Could not read targets from Turbonomic (HTTP ${r.status}).` });
    const byUuid = new Map((tryJson(r.text) || []).map((x) => [x.uuid, x]));
    const statuses = {};
    for (const u of uuids) statuses[u] = byUuid.has(u) ? (byUuid.get(u).status || 'Unknown') : 'Not found';
    res.json({ ok: true, statuses });
  } catch (e) {
    res.json({ ok: false, message: networkMessage(e, s.target) });
  }
});
// Existing WMI targets on the Turbonomic server (GET /api/v3/targets, type WMI) with their scope names. Turbonomic never
// returns the target password, so it is not included.
app.post('/api/turbonomic/targets/wmi', async (req, res) => {
  const s = await openSession(req.body);
  if (!s.ok) return res.status(s.status).json(s.body);
  try {
    const r = await turboCall({ ...s.target, method: 'GET', path: '/api/v3/targets', headers: { Cookie: s.cookie } });
    if (r.status !== 200) return res.json({ ok: false, message: `Could not read targets from Turbonomic (HTTP ${r.status}).` });
    const list = tryJson(r.text);
    if (!Array.isArray(list)) return res.json({ ok: false, message: 'Turbonomic returned an unexpected target list.' });
    const field = (x, n) => (x.inputFields || []).find((f) => f.name === n)?.value;
    const targets = list
      .filter((x) => (x.type || '').toUpperCase() === 'WMI' && x.uuid)
      .map((x) => ({
        uuid: x.uuid,
        displayName: x.displayName || field(x, 'targetId') || x.uuid,
        username: field(x, 'username') || '',
        scope: field(x, 'targetEntities') || '',
        useNtlm: String(field(x, 'useNTLM')).toLowerCase() !== 'false',
        status: x.status || 'Unknown',
      }));
    const scopeNames = {};
    for (const id of [...new Set(targets.map((t) => t.scope).filter((v) => /^[\w-]+$/.test(v)))]) {
      const g = await turboCall({ ...s.target, method: 'GET', path: `/api/v3/groups/${encodeURIComponent(id)}`, headers: { Cookie: s.cookie } });
      scopeNames[id] = (g.status === 200 && tryJson(g.text)?.displayName) || id;
    }
    for (const t of targets) t.scopeName = scopeNames[t.scope] || t.scope;
    res.json({ ok: true, targets });
  } catch (e) {
    res.json({ ok: false, message: networkMessage(e, s.target) });
  }
});

// Names of the virtual machines that are members of the given scopes (Turbonomic groups) used by the targets.
// GET /api/v3/groups/{uuid}/members is paginated with limit + x-next-cursor.
app.post('/api/turbonomic/scopes/members', async (req, res) => {
  const uuids = req.body?.uuids;
  if (!Array.isArray(uuids) || uuids.length === 0 || uuids.length > 50 || !uuids.every((u) => typeof u === 'string' && /^[\w-]+$/.test(u))) {
    return res.status(400).json({ ok: false, message: 'Provide 1-50 scope uuids.' });
  }
  const s = await openSession(req.body?.turbonomic);
  if (!s.ok) return res.status(s.status).json(s.body);
  try {
    const names = new Set();
    const members = new Map(); // displayName -> uuid
    const skipped = [];
    for (const uuid of uuids) {
      let cursor = '';
      for (let page = 0; page < 40; page += 1) {
        const qs = new URLSearchParams({ limit: '500', ...(cursor ? { cursor } : {}) });
        const r = await turboCall({ ...s.target, method: 'GET', path: `/api/v3/groups/${encodeURIComponent(uuid)}/members?${qs}`, headers: { Cookie: s.cookie } });
        // A scope that no longer exists (e.g. used by a target whose discovery failed) is skipped, not fatal.
        if (r.status === 400 || r.status === 404) { skipped.push(uuid); break; }
        if (r.status !== 200) return res.json({ ok: false, message: `Could not list the VMs in the target scope (HTTP ${r.status}).` });
        const items = tryJson(r.text);
        if (!Array.isArray(items)) return res.json({ ok: false, message: 'Turbonomic returned an unexpected member list.' });
        for (const m of items) {
          if (m?.displayName && (!m.className || m.className === 'VirtualMachine')) {
            names.add(m.displayName);
            if (m.uuid && !members.has(m.displayName)) members.set(m.displayName, m.uuid);
          }
        }
        cursor = r.headers['x-next-cursor'] || '';
        if (!cursor) break;
      }
    }
    if (skipped.length === uuids.length) {
      return res.json({ ok: false, message: 'The scope used by the targets no longer exists in Turbonomic. Add a target with a valid scope.' });
    }
    // OS and IP addresses come from GET /api/v3/entities/{uuid}/aspects (virtualMachineAspect). Prefer a private
    // (RFC1918) address, which is what the WMI target connects to.
    const isPrivate = (ip) => /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(ip);
    const sorted = [...names].sort((a, b) => a.localeCompare(b));
    const details = [];
    const lookup = async (name) => {
      const uuid = members.get(name);
      const d = { name, address: '', os: '' };
      if (uuid) {
        try {
          const a = await turboCall({ ...s.target, method: 'GET', path: `/api/v3/entities/${encodeURIComponent(uuid)}/aspects`, headers: { Cookie: s.cookie } });
          const vm = a.status === 200 ? tryJson(a.text)?.virtualMachineAspect : null;
          const ips = Array.isArray(vm?.ip) ? vm.ip.filter((x) => typeof x === 'string' && x) : [];
          d.address = ips.find(isPrivate) || ips[0] || '';
          d.os = typeof vm?.os === 'string' ? vm.os : '';
        } catch { /* leave address/os empty */ }
      }
      return d;
    };
    for (let i = 0; i < sorted.length && i < 300; i += 10) {
      details.push(...await Promise.all(sorted.slice(i, i + 10).map(lookup)));
    }
    res.json({ ok: true, vms: sorted, details, skipped });
  } catch (e) {
    res.json({ ok: false, message: networkMessage(e, s.target) });
  }
});
// Names of the VMs matching one criterion of POST /api/v3/search (Search requests). FilterApiDTO.expType only allows
// EQ/NEQ/RXEQ/RXNEQ (and numeric/set comparators) and expVal is a regex; GET /api/v3/search/criteria lists the valid
// filter types. Paginated with limit + x-next-cursor. Returns { names } or { error }.
async function searchVmNames(s, filterType, regex, what) {
  const dto = JSON.stringify({
    criteriaList: [{ filterType, expType: 'RXEQ', expVal: regex, caseSensitive: false }],
    logicalOperator: 'AND',
    className: 'VirtualMachine',
  });
  const names = new Map();
  let cursor = '';
  for (let page = 0; page < 40; page += 1) {
    const qs = new URLSearchParams({ types: 'VirtualMachine', limit: '500', ...(cursor ? { cursor } : {}) });
    const r = await turboCall({
      ...s.target, method: 'POST', path: `/api/v3/search?${qs}`,
      headers: { Cookie: s.cookie, 'Content-Type': 'application/json' }, body: dto,
    });
    if (r.status !== 200) {
      const out = tryJson(r.text);
      const detail = String((out && (out.message || out.error)) || r.text || '').replace(/\s+/g, ' ').slice(0, 200);
      return { error: `Could not search Turbonomic for ${what} (HTTP ${r.status}).${detail ? ` ${detail}` : ''}` };
    }
    const items = tryJson(r.text);
    if (!Array.isArray(items)) return { error: 'Turbonomic returned an unexpected search result.' };
    for (const e of items) {
      if (e?.displayName && (!e.className || e.className === 'VirtualMachine')) names.set(e.displayName.toLowerCase(), e.displayName);
    }
    cursor = r.headers['x-next-cursor'] || '';
    if (!cursor) break;
  }
  return { names: [...names.values()].sort((a, b) => a.localeCompare(b)) };
}

function vmSearchRoute(urlPath, filterType, regex, what) {
  app.post(urlPath, async (req, res) => {
    const s = await openSession(req.body);
    if (!s.ok) return res.status(s.status).json(s.body);
    try {
      const r = await searchVmNames(s, filterType, regex, what);
      res.json(r.error ? { ok: false, message: r.error } : { ok: true, vms: r.names });
    } catch (e) {
      res.json({ ok: false, message: networkMessage(e, s.target) });
    }
  });
}

// Linux VMs: the guest OS name (vmsByGuestName) often says "linux", but hypervisors and clouds also report
// distribution names instead, so the common ones are matched too.
vmSearchRoute('/api/turbonomic/vms/linux', 'vmsByGuestName', '.*(linux|ubuntu|red hat|rhel|centos|suse|debian|rocky|alma|amazon).*', 'Linux VMs');
// VMs with SQL Server installed: VMs that host a SQL Server application component discovered by the guest OS
// process (WMI/SSH) targets or an APM probe.
vmSearchRoute('/api/turbonomic/vms/sql', 'vmsByApplicationComponent', '.*(sql server|sqlservr|mssql).*', 'VMs with SQL Server');
// ---------------------------------------------------------------- config.json
// Only these top-level keys are persisted; anything else in the payload is dropped.
const CONFIG_KEYS = ['vault', 'turbonomic', 'targets', 'discovery', 'logging'];

function writeConfigAtomic(cfg) {
  const dir = path.dirname(CONFIG_PATH);
  fs.mkdirSync(dir, { recursive: true });
  const tmp = `${CONFIG_PATH}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(tmp, JSON.stringify(cfg, null, 2), { encoding: 'utf8', mode: 0o600 });
    if (fs.existsSync(CONFIG_PATH)) {
      const bak = `${CONFIG_PATH}.bak`;
      if (!fs.existsSync(bak)) fs.copyFileSync(CONFIG_PATH, bak); // first-ever version, kept forever
      fs.copyFileSync(CONFIG_PATH, `${CONFIG_PATH}.prev`);       // the version before this save
    }
    fs.renameSync(tmp, CONFIG_PATH); // atomic: readers never see a half-written file
  } finally {
    try { fs.rmSync(tmp, { force: true }); } catch { /* nothing to clean */ }
  }
}

app.get('/api/config', (_req, res) => {
  try {
    res.json({ path: CONFIG_PATH, config: readConfig() });
  } catch (e) {
    // A corrupt file must not lock the user out of the wizard; the next save keeps it as config.json.prev/.bak.
    res.json({ path: CONFIG_PATH, config: null, error: `config.json could not be read (${e.message}). It will be replaced when you save.` });
  }
});

app.post('/api/config', (req, res) => {
  const body = req.body;
  const v = validateConfig(body);
  if (!v.valid) return res.status(400).json({ message: `Invalid configuration: ${v.errors[0]}`, errors: v.errors });
  if (runManager.active()) return res.status(409).json({ message: 'A run is in progress. Wait for it to finish or cancel it before saving.', code: 'run_active' });
  const clean = {};
  for (const k of CONFIG_KEYS) if (body[k] !== undefined) clean[k] = body[k];
  try {
    writeConfigAtomic(clean);
    audit('config.saved', req, { windows: clean.targets.windows?.length ?? 0, linux: clean.targets.linux?.length ?? 0 });
    res.json({ ok: true, path: CONFIG_PATH });
  } catch (e) {
    console.error('config write failed:', e.message);
    res.status(500).json({ message: `Could not write config.json: ${e.code || e.message}` });
  }
});

// ---------------------------------------------------------------- runs
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const runManager = new RunManager({ cwd: ROOT, timeoutMs: RUN_TIMEOUT_MS });

app.post('/api/runs', (req, res) => {
  const { kind, days = 1, skipSqlInventory = false, skipTurbo = false } = req.body || {};
  if (kind !== 'report' && kind !== 'register') return res.status(400).json({ message: 'Unknown run kind.' });
  if (typeof skipSqlInventory !== 'boolean' || typeof skipTurbo !== 'boolean') return res.status(400).json({ message: 'skipSqlInventory and skipTurbo must be true or false.' });
  const d = Number(days);
  if (!Number.isInteger(d) || d < 1 || d > 90) return res.status(400).json({ message: 'Peak window must be a whole number of days from 1 to 90.' });
  if (!fs.existsSync(CONFIG_PATH)) return res.status(409).json({ message: 'No saved configuration. Complete the Review step first.', code: 'no_config' });

  let cmd;
  let args;
  if (kind === 'register') {
    const py = findPython();
    if (!py) return res.status(400).json({ message: 'Python 3 was not found.' });
    cmd = py.cmd;
    args = [...py.pre, '-u', path.join('target-setup', 'register_turbo_targets.py'), '--config', path.join('config', 'config.json')];
  } else {
    const ps = findPowerShell();
    if (!ps) return res.status(400).json({ message: 'PowerShell was not found.' });
    cmd = ps.cmd;
    args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', 'Invoke-FleetReport.ps1', '-Days', String(d), '-OutputDirectory', 'output'];
    if (skipSqlInventory) args.push('-SkipSqlInventory');
    if (skipTurbo) args.push('-SkipTurbo');
  }

  const r = runManager.start(kind, cmd, args, {});
  if (r.busy) return res.status(409).json({ message: 'A run is already in progress.', code: 'run_active', runId: r.busy.id });
  audit('run.started', req, { kind, runId: r.id });
  res.json({ id: r.id, command: r.command, status: r.status });
});

app.get('/api/runs', (_req, res) => res.json({ runs: runManager.list() }));

app.get('/api/runs/:id', (req, res) => {
  if (!UUID.test(req.params.id)) return res.status(404).json({ message: 'Run not found.' });
  const from = Number.parseInt(String(req.query.from ?? '0'), 10);
  const r = runManager.read(req.params.id, Number.isFinite(from) ? from : 0);
  if (!r) return res.status(404).json({ message: 'Run not found. The server may have restarted.', code: 'run_gone' });
  res.json({
    status: r.run.status, exitCode: r.run.exitCode, command: r.run.command, output: r.output, offset: r.offset,
    truncated: r.truncated, timedOut: r.run.timedOut, startedAt: r.run.startedAt, endedAt: r.run.endedAt,
  });
});

app.post('/api/runs/:id/cancel', (req, res) => {
  if (!UUID.test(req.params.id)) return res.status(404).json({ message: 'Run not found.' });
  const run = runManager.cancel(req.params.id);
  if (!run) return res.status(404).json({ message: 'Run not found.' });
  audit('run.cancelled', req, { runId: run.id });
  res.json({ ok: true, status: run.status });
});

// ---------------------------------------------------------------- generated reports
const REPORT_EXT = /\.(html|csv|json)$/i;
const normPath = (p) => (IS_WIN ? p.toLowerCase() : p);

function listFiles(dir, base = dir, acc = [], depth = 0) {
  if (depth > 4 || acc.length >= 2000 || !fs.existsSync(dir)) return acc;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.isSymbolicLink()) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) listFiles(full, base, acc, depth + 1);
    else if (REPORT_EXT.test(entry.name)) {
      try {
        const st = fs.statSync(full);
        acc.push({ path: path.relative(base, full).split(path.sep).join('/'), mtime: st.mtimeMs, size: st.size });
      } catch { /* file vanished while listing */ }
    }
  }
  return acc;
}

app.get('/api/reports', (_req, res) => {
  try {
    res.json(listFiles(OUTPUT_DIR).sort((a, b) => b.mtime - a.mtime).slice(0, 50));
  } catch (e) {
    res.status(500).json({ message: `Could not list reports: ${e.code || e.message}` });
  }
});

app.get('/api/reports/file', (req, res) => {
  const rel = typeof req.query.path === 'string' ? req.query.path : '';
  if (!rel || rel.length > 300 || rel.includes('\0') || !REPORT_EXT.test(rel)) return res.status(404).end();
  let real;
  try {
    const target = path.resolve(OUTPUT_DIR, rel);
    if (!normPath(target).startsWith(normPath(OUTPUT_DIR + path.sep))) return res.status(404).end();
    real = fs.realpathSync.native(target); // resolves symlinks: a link must not lead out of output/
    const root = fs.realpathSync.native(OUTPUT_DIR);
    if (!normPath(real).startsWith(normPath(root + path.sep)) || !fs.statSync(real).isFile()) return res.status(404).end();
  } catch {
    return res.status(404).end();
  }
  res.setHeader('X-Content-Type-Options', 'nosniff');
  if (/\.html$/i.test(real)) {
    // Reports carry inline scripts: run them in an opaque origin so they cannot reach this app's session or API.
    res.setHeader('Content-Security-Policy', REPORT_CSP);
    res.setHeader('Cache-Control', 'no-store');
  } else {
    res.setHeader('Content-Disposition', `attachment; filename="${path.basename(real).replace(/[^\w.-]/g, '_')}"`);
  }
  res.sendFile(real, { dotfiles: 'allow' }, (err) => {
    if (err && !res.headersSent) res.status(err.status === 404 ? 404 : 500).end();
  });
});

// ---------------------------------------------------------------- unknown API routes, static UI, errors
app.use('/api', (_req, res) => res.status(404).json({ message: 'Not found.' }));

const dist = path.join(APP_ROOT, 'dist');
if (fs.existsSync(dist)) {
  app.use(express.static(dist, {
    index: false,
    maxAge: '1h',
    setHeaders(res, file) {
      if (/[\\/]assets[\\/]/.test(file)) res.setHeader('Cache-Control', 'public, max-age=31536000, immutable'); // hashed names
      else res.setHeader('Cache-Control', 'no-cache');
    },
  }));
  app.get('*', (_req, res) => {
    res.setHeader('Cache-Control', 'no-cache');
    res.sendFile(path.join(dist, 'index.html'));
  });
} else {
  app.get('*', (_req, res) => res.status(503).type('text/plain').send('The UI is not built. Run "npm run build" in ola-wizard-app.'));
}

// eslint-disable-next-line no-unused-vars
app.use((err, req, res, _next) => {
  if (res.headersSent) return req.socket.destroy();
  if (err?.type === 'entity.parse.failed') return res.status(400).json({ message: 'Request body is not valid JSON.', code: 'bad_json' });
  if (err?.type === 'entity.too.large') return res.status(413).json({ message: 'Request body is too large.', code: 'too_large' });
  const ref = crypto.randomBytes(4).toString('hex');
  console.error(JSON.stringify({ ts: new Date().toISOString(), event: 'error', ref, method: req.method, path: req.path, error: String(err?.stack || err) }));
  res.status(500).json({ message: `Unexpected server error (ref ${ref}).`, code: 'server_error' });
});

// ---------------------------------------------------------------- start / stop
const server = TLS
  ? https.createServer({ cert: fs.readFileSync(TLS.cert), key: fs.readFileSync(TLS.key), minVersion: 'TLSv1.2' }, app)
  : http.createServer(app);
server.headersTimeout = 15_000;
server.requestTimeout = 30_000;
server.keepAliveTimeout = 5_000;
server.on('error', (e) => {
  console.error(e.code === 'EADDRINUSE' ? `Port ${PORT} is already in use on ${HOST}.` : `Server error: ${e.message}`);
  process.exit(1);
});

server.listen(PORT, HOST, () => {
  console.log(`OLA Onboarding Wizard on ${TLS ? 'https' : 'http'}://${HOST}:${PORT}  (toolkit root: ${ROOT})`);
  if (!TLS && !loopback(HOST)) {
    console.warn('NOTE: listening on a non-loopback address without sign-in or TLS. Anyone who can reach this port can read and change the configuration, which holds passwords. Limit access with a firewall, or set OLA_TLS_CERT/OLA_TLS_KEY.');
  }
});

let stopping = false;
function shutdown(signal) {
  if (stopping) return;
  stopping = true;
  console.log(`${signal} received: stopping.`);
  runManager.stopAll();
  server.close(() => process.exit(0));
  server.closeIdleConnections?.();
  setTimeout(() => process.exit(0), 10_000).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('unhandledRejection', (e) => console.error(JSON.stringify({ ts: new Date().toISOString(), event: 'unhandledRejection', error: String(e?.stack || e) })));
process.on('uncaughtException', (e) => {
  console.error(JSON.stringify({ ts: new Date().toISOString(), event: 'uncaughtException', error: String(e?.stack || e) }));
  runManager.stopAll();
  process.exit(1); // the container restarts the process (restart: unless-stopped)
});
