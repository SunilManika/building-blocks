import { parseHost } from './validation.js';

// Maps wizard state <-> toolkit config/config.json (inline-credential format).
// state.wmi holds the account/scope of the most recent WMI target (step 2); every Windows VM entry reuses it.
// Everything else (domain, SSH credentials) is stored per VM (step 3).

export const emptyState = () => ({
  turbonomic: { host: '', username: '', password: '' },
  wmi: { username: '', password: '', use_ntlm: true, use_https: false, scope_uuid: '' },
  vms: [],
});

export function buildConfig(state, existing) {
  const parsed = parseHost(state.turbonomic.host);
  const host = parsed.host ? (parsed.port === 443 ? parsed.host : `${parsed.host}:${parsed.port}`) : '';
  const w = state.wmi;
  const vms = state.vms.filter((v) => v.vm_name.trim() && v.address.trim());

  return {
    vault: { enabled: false },
    turbonomic: {
      host,
      api_base_url: `https://${host}/api/v3`,
      admin_username: state.turbonomic.username,
      admin_password: state.turbonomic.password,
    },
    targets: {
      windows: vms
        .filter((v) => v.os === 'Windows')
        .map((v) => ({
          display_name: `WMI-${v.vm_name}`,
          category: 'Guest OS Processes',
          type: 'WMI',
          nameOrAddress: v.address.trim(),
          vm_name: v.vm_name.trim(),
          // Per-VM credentials loaded from an existing config win; new VMs use the step-2 account.
          username: v.win_username || w.username,
          password: v.win_password || w.password,
          domain: v.domain.trim() || 'WORKGROUP',
          use_ntlm: w.use_ntlm,
          use_https: w.use_https,
          authenticate_all_db_servers: false,
          scope_uuid: w.scope_uuid || '',
        })),
      linux: vms
        .filter((v) => v.os === 'Linux')
        .map((v) => ({
          display_name: `SSH-${v.vm_name}`,
          category: 'Guest OS Processes',
          type: 'SSH',
          nameOrAddress: v.address.trim(),
          vm_name: v.vm_name.trim(),
          username: v.ssh_username,
          password: v.ssh_password,
          ssh_key_file: v.ssh_key_file.trim(),
          scope_uuid: '',
        })),
    },
    discovery: existing?.discovery ?? {
      trigger_rediscovery_after_add: true,
      rediscover_poll_interval_seconds: 15,
      rediscover_max_wait_seconds: 900,
    },
    logging: existing?.logging ?? { level: 'DEBUG', log_file: 'wmi_target_setup.log' },
  };
}

export function stateFromConfig(cfg) {
  const s = emptyState();
  if (!cfg) return s;
  const t = cfg.turbonomic || {};
  s.turbonomic = { host: t.host || '', username: t.admin_username || '', password: t.admin_password || '' };
  const win = cfg.targets?.windows || [];
  const lin = cfg.targets?.linux || [];
  if (win[0]) {
    const x = win[0];
    s.wmi = {
      username: x.username || '', password: x.password || '',
      use_ntlm: x.use_ntlm ?? true, use_https: x.use_https ?? false, scope_uuid: x.scope_uuid || '',
    };
  }
  s.vms = [
    ...win.map((x) => ({
      vm_name: x.vm_name || '', address: x.nameOrAddress || '', os: 'Windows',
      domain: x.domain || 'WORKGROUP',
      win_username: x.username || '', win_password: x.password || '',
      ssh_username: '', ssh_password: '', ssh_key_file: '',
    })),
    ...lin.map((x) => ({
      vm_name: x.vm_name || '', address: x.nameOrAddress || '', os: 'Linux',
      domain: 'WORKGROUP',
      ssh_username: x.username || '', ssh_password: x.password || '', ssh_key_file: x.ssh_key_file || '',
    })),
  ];
  return s;
}

export const maskSecrets = (cfg) =>
  JSON.parse(JSON.stringify(cfg, (k, v) => (/password/i.test(k) && v ? '********' : v)));
