# syntax=docker/dockerfile:1
# AWS OLA Onboarding Wizard - Windows container.
# Windows containers only build and run on a Windows host (Windows Server, or Docker in "Windows containers" mode).
#
# Build:  docker compose build        (see DOCKER.md)
ARG BASE_TAG=ltsc2019

# ---------------------------------------------------------------- download pinned zip tools (SHA-256 verified)
# Node.js 22 LTS, PowerShell 7.4 LTS, Win32-OpenSSH client.
FROM mcr.microsoft.com/windows/servercore:${BASE_TAG} AS tools
SHELL ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue';"]
COPY docker/Get-Tool.ps1 C:/build/Get-Tool.ps1
RUN C:\build\Get-Tool.ps1 -Url https://nodejs.org/dist/v22.23.3/node-v22.23.3-win-x64.zip -Sha256 2b0ff57b049cda1bbcea2240eec20467018713c1efe1f7360c2681859b90ed71 -Dest C:\tools\node
RUN C:\build\Get-Tool.ps1 -Url https://github.com/PowerShell/PowerShell/releases/download/v7.4.21/PowerShell-7.4.21-win-x64.zip -Sha256 b47ee814b9fe5fe6b713a26667998cadd6bbb74cb3889fadea56c775f11953a2 -Dest C:\tools\pwsh
RUN C:\build\Get-Tool.ps1 -Url https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-Win64.zip -Sha256 23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5 -Dest C:\tools\openssh

# ---------------------------------------------------------------- build the web UI
FROM tools AS ui
ENV PATH="C:\\tools\\node;C:\\Windows\\system32;C:\\Windows;C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\"
WORKDIR C:/src/ola-wizard-app
COPY ola-wizard-app/package.json ola-wizard-app/package-lock.json ./
RUN npm ci; if ($LASTEXITCODE -ne 0) { throw 'npm ci failed' }
COPY ola-wizard-app/index.html ola-wizard-app/vite.config.js ./
COPY ola-wizard-app/src ./src
COPY ola-wizard-app/server ./server
RUN npm run build; if ($LASTEXITCODE -ne 0) { throw 'vite build failed' }; \
    npm prune --omit=dev; if ($LASTEXITCODE -ne 0) { throw 'npm prune failed' }

# ---------------------------------------------------------------- runtime image
FROM mcr.microsoft.com/windows/servercore:${BASE_TAG}
SHELL ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue';"]

COPY --from=tools C:/tools C:/tools

# Python 3.13 (requests/urllib3 need >= 3.10). Installed with its own installer so the VC++ runtime is set up too.
RUN $f = 'C:\python-installer.exe'; \
    Invoke-WebRequest -UseBasicParsing -Uri https://www.python.org/ftp/python/3.13.16/python-3.13.16-amd64.exe -OutFile $f; \
    if ((Get-FileHash -Algorithm SHA256 $f).Hash -ne 'FB4F9F5D438B2396DA0086DC70B935C530CB578E37ADC6D354F7AD2037FEE83B') { throw 'Python installer checksum mismatch' }; \
    $p = Start-Process $f -ArgumentList '/quiet','InstallAllUsers=1','PrependPath=0','Include_test=0','Include_doc=0','Include_launcher=0','TargetDir=C:\Python313' -Wait -PassThru; \
    if ($p.ExitCode -ne 0) { throw ('Python install failed: ' + $p.ExitCode) }; \
    Remove-Item $f -Force; \
    & C:\Python313\python.exe -m pip install --no-cache-dir --disable-pip-version-check requests urllib3; \
    if ($LASTEXITCODE -ne 0) { throw 'pip install failed' }

ENV PATH="C:\\tools\\node;C:\\tools\\pwsh;C:\\tools\\openssh;C:\\Python313;C:\\Python313\\Scripts;C:\\Windows\\system32;C:\\Windows;C:\\Windows\\System32\\Wbem;C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\"

# Toolkit scripts at a fixed location. config/ and output/ are intentionally empty: they are bind-mounted by docker-compose.
COPY Invoke-FleetReport.ps1 C:/toolkit/
COPY collectors/ C:/toolkit/collectors/
COPY target-setup/ C:/toolkit/target-setup/
COPY --from=ui C:/src/ola-wizard-app/ C:/toolkit/ola-wizard-app/
RUN New-Item -ItemType Directory -Force C:\toolkit\config, C:\toolkit\output, C:\keys-src | Out-Null
COPY docker/entrypoint.ps1 C:/entrypoint.ps1

ENV OLA_TOOLKIT_ROOT="C:\\toolkit" \
    HOST="0.0.0.0" \
    PORT="5050" \
    NODE_ENV="production" \
    PYTHONIOENCODING="utf-8"

# Smoke-test the toolchain at build time so a bad download fails the build, not the first run.
RUN node --version; \
    pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'; \
    python --version; \
    python -c \"import requests, urllib3; print('requests', requests.__version__)\"; \
    cmd /c \"ssh -V 2>&1\"; if ($LASTEXITCODE -ne 0) { throw 'ssh.exe not runnable' }

EXPOSE 5050
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 CMD ["cmd", "/c", "curl.exe -fs -o NUL http://localhost:%PORT%/"]

ENTRYPOINT ["pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\entrypoint.ps1"]
