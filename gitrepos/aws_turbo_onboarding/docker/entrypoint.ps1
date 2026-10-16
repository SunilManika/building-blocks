# Container entrypoint for the AWS OLA Onboarding Wizard (runs under PowerShell 7).
$ErrorActionPreference = 'Continue'

# Tool locations (also set machine-wide at build time; repeated here so the process is self-sufficient).
$env:PATH = 'C:\tools\node;C:\tools\pwsh;C:\tools\openssh;C:\Python313;C:\Python313\Scripts;' + $env:PATH

$toolkit = if ($env:OLA_TOOLKIT_ROOT) { $env:OLA_TOOLKIT_ROOT } else { 'C:\toolkit' }
New-Item -ItemType Directory -Path (Join-Path $toolkit 'config'), (Join-Path $toolkit 'output') -Force | Out-Null

# --- WinRM client configuration ---
# Targets are reached by IP over plain HTTP (port 5985).  Three settings are required:
#   TrustedHosts  - allows connecting to hosts not in the Kerberos realm
#   AllowUnencrypted - allows sending credentials over HTTP (disabled by default in PS7)
#   Auth\Negotiate   - ensures NTLM is used; required on workgroup machines (no domain)
$trusted = if ($env:OLA_TRUSTED_HOSTS) { $env:OLA_TRUSTED_HOSTS } else { '*' }
try {
    Start-Service -Name WinRM -ErrorAction Stop
    Set-Item -Path WSMan:\localhost\Client\TrustedHosts    -Value $trusted -Force -ErrorAction Stop
    Set-Item -Path WSMan:\localhost\Client\AllowUnencrypted -Value $true   -Force -ErrorAction Stop
    Set-Item -Path WSMan:\localhost\Client\Auth\Negotiate   -Value $true   -Force -ErrorAction Stop
    Write-Host "WinRM client configured: TrustedHosts=$trusted, AllowUnencrypted=true, Negotiate=true"
} catch {
    Write-Warning "Could not configure WinRM client: $($_.Exception.Message). Windows targets may be unreachable."
}

# --- SSH keys: copy from the read-only mount to C:\keys and restrict the ACL, as ssh.exe requires ---
$keysSrc = 'C:\keys-src'
$keysDst = 'C:\keys'
if (Test-Path -LiteralPath $keysSrc) {
    New-Item -ItemType Directory -Path $keysDst -Force | Out-Null
    $files = @(Get-ChildItem -LiteralPath $keysSrc -File -Force -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        $dst = Join-Path $keysDst $f.Name
        Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
        & icacls.exe $dst /inheritance:r /grant:r 'Administrators:F' 'SYSTEM:F' | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "Could not restrict permissions on $dst" }
    }
    Write-Host "Prepared $($files.Count) SSH key file(s) in $keysDst"
}

# --- SSH client defaults for non-interactive use ---
# PowerShell SSH remoting (Invoke-Command -HostName) runs ssh.exe with no console to answer prompts. Without this, the first
# connection to a Linux target stops at the "authenticity of host can't be established" question, and a target without
# key authentication waits for a password. accept-new records unknown hosts but still rejects a changed host key;
# BatchMode makes missing key authentication fail immediately instead of hanging.
$sshDir = Join-Path $env:USERPROFILE '.ssh'
New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
Set-Content -LiteralPath (Join-Path $sshDir 'config') -Encoding ascii -Value @(
    'Host *',
    '    StrictHostKeyChecking accept-new',
    '    BatchMode yes',
    '    ServerAliveInterval 30'
)

# --- Start the wizard ---
Set-Location (Join-Path $toolkit 'ola-wizard-app')
Write-Host "Starting OLA Onboarding Wizard on port $($env:PORT) (toolkit root: $toolkit)"
& node.exe server/index.js
exit $LASTEXITCODE
