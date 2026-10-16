# OLA Onboarding Wizard

React UI + small Node/Express API that wraps the Turbonomic toolkit in this repository
(`config/`, `target-setup/`, `collectors/`, `Invoke-FleetReport.ps1`). Designed to run in the **Windows container**
described in [`../DOCKER.md`](../DOCKER.md), or directly on a Windows machine that has Node.js 18+, PowerShell 7 and
Python 3 with `requests`/`urllib3`.

Tabs: **Prerequisites** → 1. Turbonomic → 2. Targets → 3. VMs inventory → 4. Review & save → 5. Run

## What it does

| Tab | Behavior |
|---|---|
| Prerequisites | Turbonomic installation guides and downloads, plus the manual prerequisites (network access, target hardening, SSH keys) |
| 1. Turbonomic | Host + admin credentials; **Test connection** posts to `https://<host>/api/v3/login` |
| 2. Targets | **Add Target** popup creates WMI targets in Turbonomic (`POST /api/v3/targets`); table of added targets |
| 3. VMs inventory | Auto-populated from the VMs in the scopes of the WMI targets (with IPs); **Add Linux VM** popup for Linux targets (SSH user/password/key file) |
| 4. Review & save | Builds `config/config.json` (inline-credential format); keeps `config.json.bak` of the first existing file |
| 5. Run | Runs `register_turbo_targets.py` and `Invoke-FleetReport.ps1`, streams output, lists files in `output/` |

## Run on Windows

```powershell
cd ola-wizard-app
npm install
npm run build
npm start          # http://127.0.0.1:5050
```

Or double-click `start.bat` (installs/builds on first run).

The server binds to `127.0.0.1` only because it handles credentials and launches local scripts. Open it from a
browser on the same VM (or via an RDP session). Do not expose it externally without adding authentication and TLS.

Optional environment variables:

- `PORT` - default `5050` (1-65535; an invalid value stops the server with a clear message)
- `HOST` - bind address, default `127.0.0.1` (the container sets `0.0.0.0`)
- `OLA_TOOLKIT_ROOT` - toolkit folder; default is the parent of `ola-wizard-app` (`C:\toolkit` in the container)
- `OLA_TURBONOMIC_VERIFY_TLS` - `true` to verify Turbonomic's certificate; default `false` (self-signed accepted)
- `OLA_RUN_TIMEOUT_MINUTES` - stop a report that runs longer than this; default `120`
- `OLA_TLS_CERT` / `OLA_TLS_KEY` - PEM files; when both are set the wizard serves HTTPS
- `OLA_TRUST_PROXY` - `true` when a reverse proxy sits in front (uses `X-Forwarded-*` for client address and host)
- `OLA_ALLOWED_ORIGINS` - comma-separated extra origins allowed to call the API (for a proxy on another host name)

## Hardening built into the server

There is deliberately **no sign-in page**. Anyone who can reach the port can read and change `config.json` (which
holds passwords) and start runs, so keep the port on loopback or behind a firewall (see `DOCKER.md`). What the server
does enforce:

| Area | Behavior |
|---|---|
| Browser attacks | Cross-origin and `Sec-Fetch-Site: cross-site` writes are rejected; request bodies must be JSON; CSP, `X-Frame-Options: DENY`, `nosniff`, `no-referrer` on every response; API responses are `no-store` |
| Reports | Served with a sandboxing CSP (opaque origin) so a report's scripts cannot call the wizard API; non-HTML files download as attachments; paths are resolved through symlinks and must stay inside `output/` |
| `config.json` | Validated server-side (types, lengths, control characters, IPs/host names, duplicates, max 500 VMs); unknown keys dropped; written atomically (temp file + rename); `.bak` (first version) and `.prev` (version before the last save) kept; a corrupt file no longer blocks the UI |
| Runs | One at a time; `409` if another is active; stdin closed so a prompt cannot hang; timeout; **Stop** button kills the whole process tree; output capped at 2 MB (newest kept); finished runs pruned; a running report is found again after a page reload; saving the config is refused during a run |
| Turbonomic calls | Shared keep-alive connection pool, 20 s timeout, 32 MB response cap, loopback/link-local/multicast hosts refused, clear messages for certificate errors |
| Process | Request/header timeouts, graceful shutdown (stops active runs), unhandled errors logged as JSON with a reference id, one JSON audit line per config save and run start/stop |
| Browser UI | Request timeouts with readable network errors, error boundary instead of a blank page, load errors for the saved config are shown, run polling backs off and recovers |

## Development

```powershell
npm run dev        # Vite on :5173 (proxies /api) + API on :5050
```

## Notes

- `config/config.json` stores passwords in plain text (same as the toolkit's inline mode). Restrict NTFS permissions
  on the folder, or use the toolkit's Vault mode.
- The Turbonomic connection test accepts self-signed certificates, matching `register_turbo_targets.py`.
