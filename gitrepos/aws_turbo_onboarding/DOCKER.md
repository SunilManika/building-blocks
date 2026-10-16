# Running the AWS OLA Onboarding Wizard in Docker (Windows container)

The image bundles everything the wizard and the toolkit need, so nothing is installed on the host except Docker:

| Component | Version | Location in image |
|---|---|---|
| Base image | `mcr.microsoft.com/windows/servercore:ltsc2022` | |
| Node.js | 22 LTS (22.23.3) | `C:\tools\node` |
| PowerShell 7 (`pwsh.exe`) | 7.4.21 | `C:\tools\pwsh` |
| Python | 3.13.16 (+ `requests`, `urllib3`) | `C:\Python313` |
| OpenSSH client (`ssh.exe`) | Win32-OpenSSH 10.0.0.0p2 | `C:\tools\openssh` |
| Toolkit scripts + wizard | this repository | `C:\toolkit` (fixed) |

Python 3.13 is used instead of 3.9 because current `requests`/`urllib3` need Python 3.10 or later. Every download is
SHA-256 verified during the build.

## Host requirements

- A **Windows** host: Windows Server 2022 (or Windows 10/11 with Docker Desktop switched to *Windows containers*).
  Windows containers cannot be built or run on macOS or Linux.
- Docker Engine with Compose v2.
- For `process` isolation (default) the host OS build must match the image tag (`OLA_BASE_TAG`). Otherwise set
  `OLA_ISOLATION=hyperv` (requires the Hyper-V feature) or pick the matching tag.

## Deploy

```powershell
copy .env.example .env      # optional: adjust tag, isolation, port, TrustedHosts
docker compose up -d --build
```

Open <http://localhost:5050>. Check status with `docker compose ps` (the container reports *healthy* once the web UI answers)
and logs with `docker compose logs -f`.

Stop / remove: `docker compose down`. Rebuild after pulling changes: `docker compose up -d --build`.

## Volumes (kept on the host)

| Host folder | Container path | Purpose |
|---|---|---|
| `.\config` | `C:\toolkit\config` | `config.json` written by the wizard (holds **plaintext credentials**; restrict NTFS access) |
| `.\output` | `C:\toolkit\output` | Reports and logs from step 5. Run |
| `.\keys` (read-only) | `C:\keys-src` | SSH private keys for Linux targets. Copied to `C:\keys` with a restricted ACL at start-up; use `C:\keys\<file>` in the wizard |

`config.json` is never baked into the image (`.dockerignore`).

## Networking

The container must reach Turbonomic (HTTPS), Windows targets (WinRM) and Linux targets (SSH).

| Destination | Port |
|---|---|
| Turbonomic | 443/TCP |
| Windows target VMs (WinRM) | 5985/TCP (HTTP), 5986/TCP (HTTPS) |
| Linux target VMs (SSH) | 22/TCP |

- **Default (`nat` network).** Outbound traffic is routed through the container host, so targets see the host's IP as
  the source. This is enough in most environments. The wizard is published on `127.0.0.1:5050` only, because it has no
  authentication and handles credentials. Change `OLA_BIND` only if you put authentication/TLS in front of it.
- **Own IP on the LAN.** If target firewalls allow only a specific subnet, use the commented `transparent` or `l2bridge`
  network in `docker-compose.yml`. Port publishing does not apply there; browse to the container's IP.
- **Name resolution.** To resolve target VM names with your DNS servers, uncomment `dns:` in `docker-compose.yml`.
- **WinRM client.** At start-up the entrypoint starts the WinRM service and sets
  `WSMan:\localhost\Client\TrustedHosts` to `OLA_TRUSTED_HOSTS` (default `*`) because targets are addressed by IP.
  Narrow it (for example `10.0.*`) if you prefer.
- **SSH client.** The entrypoint writes `~\.ssh\config` with `StrictHostKeyChecking accept-new` and `BatchMode yes`.
  PowerShell SSH remoting has no console to answer prompts, so without this the first connection to a Linux target would
  hang on the host-key question. Unknown hosts are recorded on first use, a changed host key is still rejected, and a
  target without working key authentication fails immediately. The host keys are not persisted across container
  re-creation.

## Customising

Environment variables (set in `.env`): `OLA_IMAGE_TAG`, `OLA_BASE_TAG`, `OLA_ISOLATION`, `OLA_BIND`, `OLA_PORT`,
`OLA_TRUSTED_HOSTS`. Tool versions are pinned in the `Dockerfile`; update the URL and SHA-256 together.

## Status of this setup

The files were written and statically checked on a non-Windows machine, so the Windows image has **not** been built or
run. On the first Windows host, verify: `docker compose build` completes; `docker compose ps` shows *healthy*; the UI
loads on <http://localhost:5050>; a Windows target answers over WinRM; a Linux target answers over SSH using a key in
`.\keys`; and `config.json` and reports appear in `.\config` and `.\output`.
