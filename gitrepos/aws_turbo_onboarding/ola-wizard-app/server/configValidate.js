// Server-side validation of the config.json payload (the UI validates too, but the API never trusts the browser).
import { parseHost } from '../src/validation.js';

const IPV4 = /^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$/;
const HOSTNAME = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$/i;
const DOMAIN = /^[a-z0-9]([a-z0-9.-]{0,252}[a-z0-9])?$/i;
const CONTROL = /[\u0000-\u001f\u007f]/;

export const MAX_VMS = 500;

const isStr = (v) => typeof v === 'string';
const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

function text(errors, where, v, { required = true, max = 256, allowSpaceEdges = false } = {}) {
  if (v === undefined || v === null || v === '') {
    if (required) errors.push(`${where} is required.`);
    return;
  }
  if (!isStr(v)) { errors.push(`${where} must be text.`); return; }
  if (CONTROL.test(v)) errors.push(`${where} contains control characters.`);
  if (v.length > max) errors.push(`${where} is too long (max ${max}).`);
  if (!allowSpaceEdges && v !== v.trim()) errors.push(`${where} must not start or end with spaces.`);
}

function address(errors, where, v) {
  if (!isStr(v) || !v.trim()) { errors.push(`${where} is required.`); return; }
  const a = v.trim();
  if (/[\s/:@]/.test(a)) errors.push(`${where} must be only an IP address or host name.`);
  else if (/^[\d.]+$/.test(a) ? !IPV4.test(a) : !HOSTNAME.test(a)) errors.push(`${where} is not a valid IPv4 address or host name.`);
}

// Returns { valid, errors: string[] } for a config.json object.
export function validateConfig(cfg) {
  const errors = [];
  if (!isPlainObject(cfg)) return { valid: false, errors: ['The configuration must be a JSON object.'] };

  const t = cfg.turbonomic;
  if (!isPlainObject(t)) errors.push('"turbonomic" is required.');
  else {
    const h = parseHost(t.host);
    if (h.error) errors.push(`turbonomic.host: ${h.error}`);
    text(errors, 'turbonomic.admin_username', t.admin_username, { max: 256 });
    text(errors, 'turbonomic.admin_password', t.admin_password, { max: 1024, allowSpaceEdges: true });
  }

  const targets = cfg.targets;
  if (!isPlainObject(targets)) {
    errors.push('"targets" is required.');
    return { valid: false, errors };
  }
  const windows = targets.windows ?? [];
  const linux = targets.linux ?? [];
  if (!Array.isArray(windows)) errors.push('targets.windows must be a list.');
  if (!Array.isArray(linux)) errors.push('targets.linux must be a list.');
  if (errors.length) return { valid: false, errors };
  if (windows.length + linux.length > MAX_VMS) errors.push(`At most ${MAX_VMS} VMs are supported.`);

  const names = new Map();
  const addresses = new Map();
  const seen = (map, key, label, errs) => {
    const k = String(key).trim().toLowerCase();
    if (map.has(k)) errs.push(`${label} "${key}" is used more than once.`);
    map.set(k, true);
  };

  windows.forEach((w, i) => {
    const p = `targets.windows[${i}]`;
    if (!isPlainObject(w)) { errors.push(`${p} must be an object.`); return; }
    text(errors, `${p}.vm_name`, w.vm_name);
    address(errors, `${p}.nameOrAddress`, w.nameOrAddress);
    text(errors, `${p}.username`, w.username);
    text(errors, `${p}.password`, w.password, { max: 1024, allowSpaceEdges: true });
    if (/[\\@]/.test(String(w.username ?? ''))) errors.push(`${p}.username must not include a domain.`);
    if (!isStr(w.domain) || !DOMAIN.test(w.domain.trim())) errors.push(`${p}.domain must be a domain name or WORKGROUP.`);
    if (isStr(w.vm_name) && w.vm_name.trim()) seen(names, w.vm_name, 'VM name', errors);
    if (isStr(w.nameOrAddress) && w.nameOrAddress.trim()) seen(addresses, w.nameOrAddress, 'Address', errors);
  });

  linux.forEach((l, i) => {
    const p = `targets.linux[${i}]`;
    if (!isPlainObject(l)) { errors.push(`${p} must be an object.`); return; }
    text(errors, `${p}.vm_name`, l.vm_name);
    address(errors, `${p}.nameOrAddress`, l.nameOrAddress);
    text(errors, `${p}.username`, l.username);
    text(errors, `${p}.password`, l.password, { required: false, max: 1024, allowSpaceEdges: true });
    text(errors, `${p}.ssh_key_file`, l.ssh_key_file, { required: false, max: 260 });
    if (!l.password && !(isStr(l.ssh_key_file) && l.ssh_key_file.trim())) errors.push(`${p} needs a password or an SSH key file.`);
    if (isStr(l.ssh_key_file) && /(^|[\\/])\.\.([\\/]|$)/.test(l.ssh_key_file)) errors.push(`${p}.ssh_key_file must not contain "..".`);
    if (isStr(l.vm_name) && l.vm_name.trim()) seen(names, l.vm_name, 'VM name', errors);
    if (isStr(l.nameOrAddress) && l.nameOrAddress.trim()) seen(addresses, l.nameOrAddress, 'Address', errors);
  });

  if (cfg.vault !== undefined && !isPlainObject(cfg.vault)) errors.push('"vault" must be an object.');
  if (cfg.discovery !== undefined && !isPlainObject(cfg.discovery)) errors.push('"discovery" must be an object.');
  if (cfg.logging !== undefined && !isPlainObject(cfg.logging)) errors.push('"logging" must be an object.');

  return { valid: errors.length === 0, errors: errors.slice(0, 25) };
}
