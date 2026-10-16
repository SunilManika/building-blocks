# Deploying the AWS OLA Onboarding Wizard with docker-compose

Step-by-step deployment using [`docker-compose.yml`](docker-compose.yml). For design details (image contents, networking
options) see [`DOCKER.md`](DOCKER.md).

> The Windows image has not yet been built or run by the author (it was prepared on a non-Windows machine). Treat the
> first deployment as a validation run and use the checks in step 8.

## 1. Prepare the Windows container host

The image is a **Windows container**. It cannot be built or run on macOS or Linux.

1. Use Windows Server 2022, or Windows 10/11 Pro/Enterprise with Docker Desktop.
2. Install Docker Engine with Compose v2 and switch it to **Windows containers**
   (Docker Desktop: tray icon, *Switch to Windows containers*).
3. Confirm from PowerShell:

   ```powershell
   docker version --format "{{.Server.Os}}"     # must print: windows
   docker compose version                       # must be v2.x
   ```

4. Note the host OS build, which decides the isolation mode in step 4:

   ```powershell
   [System.Environment]::OSVersion.Version      # Build 20348 = Server 2022 / ltsc2022, 17763 = Server 2019 / ltsc2019
   ```

## 2. Open the network paths

The container's traffic leaves through the host, so the host and the network between it and your targets must allow:

| Destination | Port | Used for |
|---|---|---|
| Turbonomic | 443/TCP | API calls from the wizard and scripts |
| Windows target VMs | 5985/TCP (HTTP), 5986/TCP (HTTPS) | WinRM |
| Linux target VMs | 22/TCP | SSH |
| Internet (build time only) | 443/TCP | nodejs.org, github.com, python.org, pypi.org, npm registry, mcr.microsoft.com |

Targets must also be prepared as described on the wizard's Prerequisites tab (for Windows VMs, run
`target-setup\Set-WindowsPrerequisites.ps1` as Administrator and restart).

## 3. Get the files onto the host

Copy or clone this repository to the Windows host, for example to `C:\ola`, and work from its root (the folder that
contains `docker-compose.yml`):

```powershell
cd C:\ola
dir docker-compose.yml, Dockerfile, .dockerignore, docker, collectors, target-setup, ola-wizard-app
```

The folders `config`, `output` and `keys` must exist next to `docker-compose.yml`. They are bind-mounted into the
container.

```powershell
New-Item -ItemType Directory -Force config, output, keys | Out-Null
```

## 4. Configure the deployment (optional)

Without a `.env` file the defaults are used (`ltsc2022`, `process` isolation, `127.0.0.1:5050`, TrustedHosts `*`).

```powershell
copy .env.example .env
notepad .env
```

| Variable | Default | Change it when |
|---|---|---|
| `OLA_BASE_TAG` | `ltsc2022` | Host is Server 2019 (`ltsc2019`) or another build |
| `OLA_ISOLATION` | `process` | Host and image OS builds differ: use `hyperv` (needs the Hyper-V feature) |
| `OLA_BIND` | `127.0.0.1` | You must reach the wizard from another machine. The wizard has **no authentication**, so put authentication/TLS in front of it first |
| `OLA_PORT` | `5050` | Port 5050 is taken on the host |
| `OLA_TRUSTED_HOSTS` | `*` | You want to restrict WinRM trusted hosts, for example `10.0.*` |
| `OLA_IMAGE_TAG` | `latest` | You want to version your builds |

Optional settings in `docker-compose.yml`:

- Uncomment `dns:` to use specific DNS servers for resolving target VM names.
- Replace the `nat` network with the commented `transparent` or `l2bridge` block if the targets only accept
  connections from a particular subnet. Port publishing does not apply on those networks; browse to the container's IP.

## 5. Provide secrets and keys

- **`config\config.json`** is written by the wizard (step 4. Review, "Continue to run"). It contains plaintext
  credentials. Restrict NTFS permissions on `config\` to administrators. If you already have a `config.json`, put it
  there and the wizard will load it.
- **SSH keys** (only for Linux targets): copy the private key files into `keys\`. In the wizard, enter the path as
  `C:\keys\<file name>`. At start-up the container copies them to `C:\keys` and restricts their permissions, as
  `ssh.exe` requires. The `keys` mount is read-only.

## 6. Validate the compose file

```powershell
docker compose config
```

This prints the resolved configuration and fails on syntax or variable errors.

## 7. Build and start

```powershell
docker compose up -d --build
```

The first build downloads and verifies Node.js, PowerShell 7, Python, OpenSSH and the npm packages, so it takes
several minutes. The build fails (rather than the first run) if a download checksum or tool smoke test fails.

Follow progress:

```powershell
docker compose logs -f
```

## 8. Verify

1. **Health:** `docker compose ps`. The `ola-wizard` service should become `healthy` within about a minute.
2. **UI:** open <http://localhost:5050> (or your `OLA_BIND`/`OLA_PORT` values). The Prerequisites tab should load.
3. **Toolchain inside the container:**

   ```powershell
   docker compose exec ola-wizard pwsh -NoProfile -Command "node --version; python --version; python -c 'import requests, urllib3; print(requests.__version__)'; ssh -V; $PSVersionTable.PSVersion.ToString()"
   ```

4. **WinRM client setting:**

   ```powershell
   docker compose exec ola-wizard pwsh -NoProfile -Command "(Get-Item WSMan:\localhost\Client\TrustedHosts).Value"
   ```

5. **Reachability** (replace the addresses):

   ```powershell
   docker compose exec ola-wizard pwsh -NoProfile -Command "Test-NetConnection <turbonomic-host> -Port 443; Test-NetConnection <windows-vm-ip> -Port 5985; Test-NetConnection <linux-vm-ip> -Port 22"
   ```

6. **Persistence:** complete the wizard through step 4 and confirm `config\config.json` appears on the host; run a
   step 5 action and confirm files appear in `output\`.

## 9. Use the wizard

Open the UI and go through Prerequisites, 1. Turbonomic, 2. Targets, 3. VMs inventory, 4. Review and 5. Run.
The scripts run inside the container from `C:\toolkit`.

## 10. Operate

| Task | Command |
|---|---|
| Status | `docker compose ps` |
| Logs | `docker compose logs -f` |
| Restart | `docker compose restart` |
| Stop (keeps config/output) | `docker compose down` |
| Update after pulling new code | `docker compose up -d --build` |
| Shell inside the container | `docker compose exec ola-wizard pwsh` |
| Remove the image | `docker compose down --rmi local` |

Your data is in `config\` and `output\` on the host, so it survives rebuilds and `docker compose down`.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `no matching manifest for windows/amd64` or `image operating system "windows" cannot be used on this platform` | Docker is in Linux-containers mode. Switch to Windows containers (step 1) |
| `The container operating system does not match the host operating system` | Host and image builds differ. Set `OLA_BASE_TAG` to the matching tag, or `OLA_ISOLATION=hyperv` |
| Build fails with `SHA-256 mismatch` | A pinned download changed or was altered in transit. Do not bypass the check; update the URL and hash in the `Dockerfile` after verifying the source |
| Build fails downloading a tool | The host cannot reach the internet or a proxy blocks it. Allow the hosts listed in step 2 |
| `bind source path does not exist` / mount errors | Create `config`, `output`, `keys` (step 3). Windows bind mounts expect directories |
| Container is `unhealthy` | `docker compose logs ola-wizard`. Check port 5050 is not already in use inside the container (`PORT`) |
| Wizard unreachable at `localhost:5050` | `OLA_BIND`/`OLA_PORT` differ from what you browse to, or you use a `transparent`/`l2bridge` network (use the container IP) |
| WinRM errors to Windows targets | Run `Set-WindowsPrerequisites.ps1` on the target, allow 5985/5986, check `TrustedHosts` (step 8.4) |
| SSH errors to Linux targets (`UNPROTECTED PRIVATE KEY FILE`) | Use the `C:\keys\<file>` path, not `C:\keys-src`; check the entrypoint log line "Prepared N SSH key file(s)" |
| Names do not resolve | Set `dns:` in `docker-compose.yml`, or use IP addresses |
