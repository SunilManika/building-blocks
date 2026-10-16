// Shared by the browser (inline field errors) and the Node API (authoritative re-check).

const IPV4 = /^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$/;
const HOSTNAME = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$/i;

// Accepts "host", "host:port", "https://host[:port]/optional/path". Returns { host, port, error }.
export function parseHost(input) {
  const raw = String(input ?? '').trim();
  if (!raw) return { error: 'Host is required.' };
  if (/\s/.test(raw)) return { error: 'Host must not contain spaces.' };
  if (/^http:\/\//i.test(raw)) return { error: 'Use HTTPS. Turbonomic API calls are not accepted over http://.' };
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(raw) && !/^https:\/\//i.test(raw)) {
    return { error: 'Only https:// URLs are supported.' };
  }

  const authority = raw.replace(/^https:\/\//i, '').replace(/[/?#].*$/, '');
  if (authority.includes('@')) return { error: 'Do not include credentials in the host.' };

  const m = authority.match(/^(.+?)(?::(\d{1,5}))?$/);
  const host = m?.[1] ?? '';
  const port = m?.[2] ? Number(m[2]) : 443;
  if (!host) return { error: 'Host is required.' };
  if (port < 1 || port > 65535) return { error: 'Port must be between 1 and 65535.' };

  if (/^[\d.]+$/.test(host)) {
    if (!IPV4.test(host)) return { error: 'Not a valid IPv4 address.' };
  } else if (!HOSTNAME.test(host)) {
    return { error: 'Not a valid hostname (e.g. customer.turbonomic.ibm.com).' };
  }
  return { host, port };
}

export function validateTurbonomic({ host, username, password } = {}) {
  const errors = {};
  const h = parseHost(host);
  if (h.error) errors.host = h.error;

  const u = String(username ?? '');
  if (!u.trim()) errors.username = 'Admin username is required.';
  else if (u !== u.trim()) errors.username = 'Username must not start or end with spaces.';
  else if (u.length > 256) errors.username = 'Username is too long.';

  const p = String(password ?? '');
  if (!p) errors.password = 'Admin password is required.';
  else if (p.length > 1024) errors.password = 'Password is too long.';

  return { valid: Object.keys(errors).length === 0, errors, target: h };
}

// Identifies the exact host/username/password combination that was verified.
export const credentialFingerprint = (t = {}) => JSON.stringify([String(t.host ?? '').trim(), t.username ?? '', t.password ?? '']);

// Rules for the "Add Target" (WMI) form.
export function validateWmiTarget({ displayName, username, password, scope } = {}) {
  const errors = {};

  const n = String(displayName ?? '');
  if (!n.trim()) errors.displayName = 'Display name is required.';
  else if (n.trim().length > 128) errors.displayName = 'Display name must be 128 characters or fewer.';

  const u = String(username ?? '');
  if (!u.trim()) errors.username = 'Username is required.';
  else if (u !== u.trim()) errors.username = 'Username must not start or end with spaces.';
  else if (/[\\@]/.test(u)) errors.username = 'Enter the username without the domain (no "DOMAIN\\" or "@domain").';
  else if (u.length > 256) errors.username = 'Username is too long.';

  const p = String(password ?? '');
  if (!p) errors.password = 'Password is required.';
  else if (p.length > 1024) errors.password = 'Password is too long.';

  if (!String(scope ?? '').trim()) errors.scope = 'Select a scope.';

  return { valid: Object.keys(errors).length === 0, errors };
}

// ---------------------------------------------------------------- VMs inventory
const IP_OR_HOST = (v) => (/^[\d.]+$/.test(v) ? IPV4.test(v) : HOSTNAME.test(v));
const DOMAIN = /^[a-z0-9]([a-z0-9.-]{0,252}[a-z0-9])?$/i;

export const emptyVm = () => ({
  vm_name: '', address: '', os: 'Windows',
  domain: 'WORKGROUP',
  ssh_username: '', ssh_password: '', ssh_key_file: '',
});

// Rules for one VM row. `otherNames` are the names of the other VMs (case-insensitive duplicate check).
export function validateVm(vm = {}, otherNames = []) {
  const errors = {};

  const name = String(vm.vm_name ?? '');
  if (!name.trim()) errors.vm_name = 'VM name is required.';
  else if (name !== name.trim()) errors.vm_name = 'VM name must not start or end with spaces.';
  else if (name.length > 256) errors.vm_name = 'VM name is too long.';
  else if (otherNames.some((n) => String(n).trim().toLowerCase() === name.toLowerCase())) errors.vm_name = 'Another VM already uses this name.';

  const addr = String(vm.address ?? '').trim();
  if (!addr) errors.address = 'IP address or hostname is required.';
  else if (/[\s/:@]/.test(addr)) errors.address = 'Enter only an IP address or hostname (no spaces, port, or URL).';
  else if (!IP_OR_HOST(addr)) errors.address = 'Not a valid IPv4 address or hostname.';

  if (vm.os !== 'Windows' && vm.os !== 'Linux') errors.os = 'Select Windows or Linux.';

  if (vm.os === 'Windows') {
    const d = String(vm.domain ?? '').trim();
    if (!d) errors.domain = 'Enter the domain, or WORKGROUP for local accounts.';
    else if (!DOMAIN.test(d)) errors.domain = 'Not a valid domain name (letters, digits, dots and hyphens only).';
  }

  if (vm.os === 'Linux') {
    const u = String(vm.ssh_username ?? '');
    if (!u.trim()) errors.ssh_username = 'SSH username is required.';
    else if (u !== u.trim()) errors.ssh_username = 'SSH username must not start or end with spaces.';
    if (!vm.ssh_password && !String(vm.ssh_key_file ?? '').trim()) {
      errors.ssh_password = 'Enter an SSH password or an SSH private key file.';
      errors.ssh_key_file = 'Enter an SSH private key file or an SSH password.';
    }
  }

  return { valid: Object.keys(errors).length === 0, errors };
}
