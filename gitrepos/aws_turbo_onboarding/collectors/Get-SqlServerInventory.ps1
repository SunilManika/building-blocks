<#
.SYNOPSIS
    Centralized remote SQL Server inventory collector and HTML dashboard.

.DESCRIPTION
    Reads VM names/addresses from CSV. For each VM, uses PowerShell Remoting to
    execute a collector remotely. The remote collector uses CIM/WMI for Windows
    and SQL Server discovery and SQL Server metadata queries for database details.

    Outputs:
      - HTML dashboard
      - JSON source data
      - CSV instance inventory
      - CSV database inventory
      - execution log

    Designed for Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER MaxFailedAuthAttempts
    Stop collecting after this many consecutive WinRM "Access is denied" failures
    against the same global credential.  Prevents account lockout when the
    password is wrong and the script is re-run multiple times.
    Default: 3.  Set to 0 to disable the guard entirely.

.NOTES
    Run this script from a central Windows management VM.

    Required remote capabilities:
      - WinRM / PowerShell Remoting enabled on each target VM
      - Target addresses in WinRM TrustedHosts (handled automatically)
      - Local admin account on each target VM
      - LocalAccountTokenFilterPolicy = 1 on each target VM

    Account lockout prevention:
      - Always supply an explicit -Credential (or per-server credentials in
        config.json) rather than relying on -UseCurrentCredential for workgroup
        targets.  NTLM pass-through fails on workgroup machines, and every
        failed attempt counts toward the lockout threshold.
      - The -MaxFailedAuthAttempts guard (default 3) automatically skips
        remaining targets once the credential is proven bad.
      - After each successful collection the script logs off disconnected
        WinRM sessions on the target to prevent stale session accumulation.
#>

[CmdletBinding()]
param(
    [string]$InputFile = "..\config\config.json",

    [string]$OutputDirectory = ".\output",

    [System.Management.Automation.PSCredential]$Credential,

    [switch]$UseCurrentCredential,

    [int]$OperationTimeoutSec = 300,

    [switch]$SkipDatabaseDetails,

    [switch]$SkipNetworkDetails,

    # Stop collecting after this many consecutive "Access is denied" / auth failures
    # on the SAME credential.  Prevents account lockout when the password is wrong.
    # Set to 0 to disable the guard (collect all targets regardless).
    [int]$MaxFailedAuthAttempts = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$runStamp = Get-Date -Format 'yyyyMMdd-HHmmssff'
$jsonPath        = Join-Path $OutputDirectory "sql-inventory-$runStamp.json"
$htmlPath        = Join-Path $OutputDirectory "sql-inventory-$runStamp.html"
$instanceCsvPath = Join-Path $OutputDirectory "sql-inventory-instances-$runStamp.csv"
$databaseCsvPath = Join-Path $OutputDirectory "sql-inventory-databases-$runStamp.csv"
$logPath         = Join-Path $OutputDirectory "sql-inventory-$runStamp.log"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level = 'INFO'
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $logPath -Value $line
}

function HtmlEncode {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

# ---------------------------------------------------------------------------
# INPUT (Supports JSON config like config/config.json or legacy CSV)
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $InputFile)) {
    # Check fallback relative paths
    $candidatePaths = @(
        $InputFile,
        (Join-Path $PSScriptRoot $InputFile),
        (Join-Path $PSScriptRoot "..\config\config.json"),
        (Join-Path (Get-Location) $InputFile),
        (Join-Path (Get-Location) "config\config.json")
    )
    $resolved = $candidatePaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($resolved) {
        $InputFile = $resolved
    } else {
        throw "Input file not found: $InputFile"
    }
}

$rawInputRows = @()
$isJsonInput = $InputFile.EndsWith('.json', [System.StringComparison]::OrdinalIgnoreCase)

if ($isJsonInput) {
    $jsonObj = Get-Content -LiteralPath $InputFile -Raw -Encoding UTF8 | ConvertFrom-Json

    # Check if HashiCorp Vault is enabled in config
    $useVault = ($jsonObj.PSObject.Properties.Name -contains 'vault' -and $jsonObj.vault -and $jsonObj.vault.enabled)
    $vaultSecrets = @{}

    if ($useVault) {
        Write-Log "HashiCorp Vault is enabled in config. Resolving target credentials from Vault..."
        $vaultAddr = if ($env:VAULT_ADDR) { $env:VAULT_ADDR } elseif ($jsonObj.vault.address) { $jsonObj.vault.address } else { "https://127.0.0.1:8200" }
        $vaultAddr = $vaultAddr.TrimEnd('/')
        $roleId    = if ($env:VAULT_ROLE_ID) { $env:VAULT_ROLE_ID } elseif ($jsonObj.vault.PSObject.Properties.Name -contains 'role_id') { $jsonObj.vault.role_id } else { "" }
        $secretId  = if ($env:VAULT_SECRET_ID) { $env:VAULT_SECRET_ID } elseif ($jsonObj.vault.PSObject.Properties.Name -contains 'secret_id') { $jsonObj.vault.secret_id } else { "" }
        $token     = if ($env:VAULT_TOKEN) { $env:VAULT_TOKEN } elseif ($jsonObj.vault.PSObject.Properties.Name -contains 'token') { $jsonObj.vault.token } else { "" }
        $kvMount   = if ($jsonObj.vault.PSObject.Properties.Name -contains 'kv_mount' -and $jsonObj.vault.kv_mount) { [string]$jsonObj.vault.kv_mount.Trim('/') } else { "secret" }

        # Check local approle-credentials.json if credentials are not in env/config
        if (-not $token -and (-not $roleId -or -not $secretId)) {
            $candidateApprole = @(
                "output\approle-credentials.json",
                "vault-setup\output\approle-credentials.json",
                (Join-Path $PSScriptRoot "..\vault-setup\output\approle-credentials.json"),
                (Join-Path $PSScriptRoot "..\output\approle-credentials.json")
            )
            foreach ($ap in $candidateApprole) {
                if (Test-Path $ap) {
                    try {
                        $apData = Get-Content -LiteralPath $ap -Raw | ConvertFrom-Json
                        if (-not $roleId) { $roleId = $apData.role_id }
                        if (-not $secretId) { $secretId = $apData.secret_id }
                        if (-not $jsonObj.vault.address -and $apData.vault_addr) { $vaultAddr = $apData.vault_addr.TrimEnd('/') }
                        break
                    } catch {}
                }
            }
        }

        # AppRole login if token not directly provided
        if (-not $token) {
            if (-not $roleId -or -not $secretId) {
                Write-Log "WARNING: Vault is enabled but VAULT_TOKEN / AppRole credentials not found. Will fall back to config fields."
            } else {
                try {
                    $loginBody = @{ role_id = $roleId; secret_id = $secretId } | ConvertTo-Json
                    $loginResp = Invoke-RestMethod -Uri "$vaultAddr/v1/auth/approle/login" -Method Post -Body $loginBody -ContentType "application/json" -SkipCertificateCheck -ErrorAction Stop
                    $token = $loginResp.auth.client_token
                } catch {
                    Write-Log "WARNING: Vault AppRole authentication failed ($($_.Exception.Message)). Will fall back to config fields."
                }
            }
        }

        # Helper scriptblock to fetch secret
        $fetchVaultSecret = {
            param([string]$path)
            if (-not $token) { return $null }
            $cleanPath = $path.TrimStart('/')
            foreach ($pfx in @("$kvMount/data/", "$kvMount/", "data/")) {
                if ($cleanPath.StartsWith($pfx)) { $cleanPath = $cleanPath.Substring($pfx.Length) }
            }
            try {
                $secResp = Invoke-RestMethod -Uri "$vaultAddr/v1/$kvMount/data/$cleanPath" -Method Get -Headers @{ 'X-Vault-Token' = $token } -SkipCertificateCheck -ErrorAction Stop
                return $secResp.data.data
            } catch {
                Write-Log "WARNING: Failed to retrieve Vault secret at '$path': $($_.Exception.Message)"
                return $null
            }
        }
    }

    if ($jsonObj.targets) {
        if ($jsonObj.targets.windows) {
            foreach ($w in $jsonObj.targets.windows) {
                $sec = $null
                if ($useVault -and ($w.PSObject.Properties.Name -contains 'vault_path') -and $w.vault_path) {
                    $sec = & $fetchVaultSecret $w.vault_path
                }

                $wUser   = if ($sec -and ($sec.PSObject.Properties.Name -contains 'username') -and $sec.username) { [string]$sec.username } elseif ($w.PSObject.Properties.Name -contains 'username' -and $w.username) { [string]$w.username } else { '' }
                $wPass   = if ($sec -and ($sec.PSObject.Properties.Name -contains 'password') -and $sec.password) { [string]$sec.password } elseif ($w.PSObject.Properties.Name -contains 'password' -and $w.password) { [string]$w.password } else { '' }
                $wDomain = if ($sec -and ($sec.PSObject.Properties.Name -contains 'domain')   -and $sec.domain)   { [string]$sec.domain   } elseif ($w.PSObject.Properties.Name -contains 'domain'   -and $w.domain)   { [string]$w.domain   } else { '' }

                # Qualify the username with its domain/machine prefix so WinRM
                # NTLM auth resolves it correctly:
                #   WORKGROUP (or blank) -> .\username  (local account on target)
                #   any other domain     -> DOMAIN\username
                # Without this, a bare username can be misrouted to a domain
                # lookup and fail even when the password is correct.
                $wUserQualified = $wUser
                if (-not [string]::IsNullOrWhiteSpace($wUser)) {
                    if ([string]::IsNullOrWhiteSpace($wDomain) -or $wDomain -ieq 'WORKGROUP') {
                        # Prepend .\ only when the caller hasn't already qualified it
                        if ($wUser -notmatch '\\') { $wUserQualified = ".\$wUser" }
                    } elseif ($wUser -notmatch '\\') {
                        $wUserQualified = "$wDomain\$wUser"
                    }
                }

                $rawInputRows += [PSCustomObject]@{
                    Name          = if ($w.PSObject.Properties.Name -contains 'vm_name'      -and $w.vm_name)      { $w.vm_name      } else { $w.display_name }
                    Address       = if ($w.PSObject.Properties.Name -contains 'nameOrAddress' -and $w.nameOrAddress){ $w.nameOrAddress } else { $w.vm_name }
                    OS            = 'Windows'
                    Username      = $wUserQualified
                    Password      = $wPass
                    SSHKeyFile    = ''
                    ForcePassive  = if ($w.PSObject.Properties.Name -contains 'force_passive') { [string]$w.force_passive } else { '' }
                    MinVCPUs      = if ($w.PSObject.Properties.Name -contains 'min_vcpus')     { $w.min_vcpus     } else { $null }
                    MinRAMGB      = if ($w.PSObject.Properties.Name -contains 'min_ram_gb')    { $w.min_ram_gb    } else { $null }
                }
            }
        }
        if ($jsonObj.targets.linux) {
            foreach ($l in $jsonObj.targets.linux) {
                $sec = $null
                if ($useVault -and ($l.PSObject.Properties.Name -contains 'vault_path') -and $l.vault_path) {
                    $sec = & $fetchVaultSecret $l.vault_path
                }

                $lUser = if ($sec -and ($sec.PSObject.Properties.Name -contains 'username') -and $sec.username) { [string]$sec.username } elseif ($l.PSObject.Properties.Name -contains 'username' -and $l.username) { [string]$l.username } else { '' }
                $lPass = if ($sec -and ($sec.PSObject.Properties.Name -contains 'password') -and $sec.password) { [string]$sec.password } elseif ($l.PSObject.Properties.Name -contains 'password' -and $l.password) { [string]$l.password } else { '' }

                $rawInputRows += [PSCustomObject]@{
                    Name          = if ($l.PSObject.Properties.Name -contains 'vm_name'      -and $l.vm_name)      { $l.vm_name      } else { $l.display_name }
                    Address       = if ($l.PSObject.Properties.Name -contains 'nameOrAddress' -and $l.nameOrAddress){ $l.nameOrAddress } else { $l.vm_name }
                    OS            = 'Linux'
                    Username      = $lUser
                    Password      = $lPass
                    SSHKeyFile    = if ($l.PSObject.Properties.Name -contains 'ssh_key_file'  -and $l.ssh_key_file) { $l.ssh_key_file  } else { '' }
                    ForcePassive  = if ($l.PSObject.Properties.Name -contains 'force_passive') { [string]$l.force_passive } else { '' }
                    MinVCPUs      = if ($l.PSObject.Properties.Name -contains 'min_vcpus')     { $l.min_vcpus     } else { $null }
                    MinRAMGB      = if ($l.PSObject.Properties.Name -contains 'min_ram_gb')    { $l.min_ram_gb    } else { $null }
                }
            }
        }
    }
} else {
    $rawInputRows = @(Import-Csv -LiteralPath $InputFile)
}

if ($rawInputRows.Count -eq 0) {
    throw "Input contains no records: $InputFile"
}

$servers = @(foreach ($row in $rawInputRows) {
    $name    = [string]$row.Name
    $address = [string]$row.Address

    if ([string]::IsNullOrWhiteSpace($name) -and [string]::IsNullOrWhiteSpace($address)) {
        continue
    }
    if ([string]::IsNullOrWhiteSpace($address)) {
        $address = $name
    }

    # OS type - 'Windows' (default) or 'Linux'
    $rowOS = if ($row.PSObject.Properties.Name -contains 'OS' -and $row.OS) { ([string]$row.OS).Trim() } else { 'Windows' }
    if ([string]::IsNullOrWhiteSpace($rowOS)) { $rowOS = 'Windows' }
    $isLinuxOS = $rowOS -eq 'Linux'

    # Per-server credential (WinRM for Windows, SSH for Linux)
    $rowUsername = if ($row.PSObject.Properties.Name -contains 'Username' -and $row.Username) { [string]$row.Username } else { '' }
    $rowPassword = if ($row.PSObject.Properties.Name -contains 'Password' -and $row.Password) { [string]$row.Password } else { '' }

    # SSH key file path (Linux only; optional - falls back to password auth)
    $sshKeyFile = if ($row.PSObject.Properties.Name -contains 'SSHKeyFile' -and $row.SSHKeyFile) { [string]$row.SSHKeyFile } else { '' }

    # Build PSCredential only for Windows (WinRM requires it); Linux uses SSH key or plain user/pass
    $rowCredential = $null
    if (-not $isLinuxOS -and -not [string]::IsNullOrWhiteSpace($rowUsername) -and -not [string]::IsNullOrWhiteSpace($rowPassword)) {
        $securePassword = ConvertTo-SecureString $rowPassword -AsPlainText -Force
        $rowCredential  = New-Object System.Management.Automation.PSCredential($rowUsername, $securePassword)
    }

    # Manual/vendor fields - not discoverable from SQL Server
    $forcePassive = if ($row.PSObject.Properties.Name -contains 'ForcePassive' -and $row.ForcePassive) { [string]$row.ForcePassive } else { '' }
    $minVCPUs     = if ($row.PSObject.Properties.Name -contains 'MinVCPUs' -and $row.MinVCPUs)     { [string]$row.MinVCPUs     } else { '' }
    $minRAMGB     = if ($row.PSObject.Properties.Name -contains 'MinRAMGB' -and $row.MinRAMGB)     { [string]$row.MinRAMGB     } else { '' }

    [PSCustomObject]@{
        Name            = $name
        Address         = $address
        OS              = $rowOS
        IsLinuxOS       = $isLinuxOS
        Credential      = $rowCredential      # PSCredential (Windows only)
        WmiUsername     = $rowUsername
        SSHKeyFile      = $sshKeyFile         # path to private key (Linux)
        SSHPassword     = $rowPassword        # plain text only held in memory for SSH (Linux)
        ForcePassive    = $forcePassive
        MinVCPUs        = $minVCPUs
        MinRAMGB        = $minRAMGB
    }
})

if ($servers.Count -eq 0) {
    throw "No valid VM records were found."
}

# ---------------------------------------------------------------------------
# POWERSHELL VERSION CHECK - SSH remoting (-HostName/-UserName/-KeyFilePath)
# requires PowerShell 7+.  Fail fast with a clear message if Linux servers
# are present and the script is running under Windows PowerShell 5.1.
# ---------------------------------------------------------------------------

$linuxServers = @($servers | Where-Object { $_.IsLinuxOS })
if ($linuxServers.Count -gt 0 -and $PSVersionTable.PSVersion.Major -lt 7) {
    Write-Log ("Linux server(s) found ($($linuxServers.Name -join ', ')) but this script is running " +
               "under Windows PowerShell $($PSVersionTable.PSVersion). " +
               "SSH remoting requires PowerShell 7+. " +
               "Linux targets will be SKIPPED - Windows targets will still be collected. " +
               "To collect Linux targets, re-run using: pwsh -File `"$PSCommandPath`" -InputFile `"$InputFile`" -OutputDirectory `"$OutputDirectory`"") 'WARN'
    # Remove Linux servers from the collection list so Windows collection proceeds normally.
    $servers = @($servers | Where-Object { -not $_.IsLinuxOS })
    if ($servers.Count -eq 0) {
        Write-Log "No Windows servers remain after excluding Linux targets. Nothing to collect." 'WARN'
        # Write an empty-but-valid JSON so the orchestrator can still find the file.
        [PSCustomObject]@{
            GeneratedAt  = (Get-Date).ToUniversalTime().ToString('o')
            Collector    = [string]$env:COMPUTERNAME
            VMCount      = 0
            SuccessCount = 0
            FailureCount = 0
            Servers      = @()
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
        exit 0
    }
}

# ---------------------------------------------------------------------------
# AUTHENTICATION
# ---------------------------------------------------------------------------

# Only prompt for a global credential when at least one non-localhost Windows
# server has no per-row credential and neither -UseCurrentCredential nor
# -Credential was supplied.  Linux servers use SSH - no PSCredential needed.
#
# When every Windows server has username+password in config.json the per-row
# PSCredential is already built above, so $serversNeedingGlobalCred will be
# empty and the interactive prompt is automatically skipped.
$serversNeedingGlobalCred = @(
    $servers | Where-Object {
        -not $_.IsLinuxOS -and
        $null -eq $_.Credential -and
        $_.Address -notin @('localhost', '127.0.0.1', '::1')
    }
)

$coveredByConfig = ($servers | Where-Object { -not $_.IsLinuxOS -and $null -ne $_.Credential }).Count
if ($coveredByConfig -gt 0) {
    Write-Log "Using per-server credentials from config for $coveredByConfig Windows target(s) - no global credential needed"
}

if (-not $UseCurrentCredential -and $null -eq $Credential -and $serversNeedingGlobalCred.Count -gt 0) {
    $Credential = Get-Credential -Message 'Credential for remote Windows VM inventory collection'
}

if ($UseCurrentCredential) {
    $Credential = $null
}

# ---------------------------------------------------------------------------
# WINRM CLIENT - AllowUnencrypted + Negotiate must be set on the COLLECTOR
# machine (not just the targets) for pwsh 7 to send credentials over HTTP.
# These are non-destructive: they only affect outbound WinRM connections
# from this machine and are required on both the Docker container and any
# Windows host running the script directly.
# ---------------------------------------------------------------------------

$hasWindowsTargets = @($servers | Where-Object { -not $_.IsLinuxOS -and
    $_.Address -notin @('localhost','127.0.0.1','::1') }).Count -gt 0

if ($hasWindowsTargets) {
    try {
        Set-Item WSMan:\localhost\Client\AllowUnencrypted -Value $true -Force -ErrorAction Stop
        Set-Item WSMan:\localhost\Client\Auth\Negotiate   -Value $true -Force -ErrorAction Stop
        Write-Log "WinRM client: AllowUnencrypted=true, Negotiate=true"
    } catch {
        Write-Log "Could not set WinRM client options: $($_.Exception.Message) - collection may fail" 'WARN'
    }
}

# ---------------------------------------------------------------------------
# TRUSTEDHOSTS - only for Windows targets; Linux uses SSH (no WinRM)
# ---------------------------------------------------------------------------

$addedTrustedHosts = @()

try {
    $currentTrusted = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
} catch {
    $currentTrusted = ''
}

foreach ($server in $servers) {
    if ($server.IsLinuxOS) { continue }   # SSH transport - TrustedHosts not needed
    $addr = $server.Address
    if ($addr -in @('localhost', '127.0.0.1', '::1')) { continue }

    $alreadyTrusted = ($currentTrusted -eq '*') -or
                      (@($currentTrusted -split ',' |
                         ForEach-Object { $_.Trim() } |
                         Where-Object { $_ -eq $addr }).Count -gt 0)

    if (-not $alreadyTrusted) {
        $newValue = if ([string]::IsNullOrWhiteSpace($currentTrusted)) {
            $addr
        } else {
            "$currentTrusted,$addr"
        }
        try {
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newValue -Force -ErrorAction Stop
            $currentTrusted = $newValue
            $addedTrustedHosts += $addr
            Write-Log "Added $addr to TrustedHosts"
        } catch {
            Write-Log "Could not update TrustedHosts for $addr - $($_.Exception.Message)" 'WARN'
        }
    }
}

# ---------------------------------------------------------------------------
# REMOTE COLLECTOR - defined as a string then compiled to avoid PS 5.1
# scriptblock-serialisation issues when passed to Invoke-Command.
# Arguments arrive via $args[0]/$args[1] as plain strings '0'/'1'.
# ---------------------------------------------------------------------------

$RemoteCollectorSource = @'
$SkipDatabaseDetails = ($args[0] -eq '1')
$SkipNetworkDetails  = ($args[1] -eq '1')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

function SafeGet {
    param([scriptblock]$Code)
    try { & $Code } catch { $null }
}

function RegValue {
    param([string]$Path, [string]$Name)
    try {
        if (Test-Path -LiteralPath $Path) {
            return (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name
        }
    } catch {}
    return $null
}

function Get-SqlNamespaces {
    $candidates = @(
        'root\Microsoft\SqlServer\ComputerManagement17',
        'root\Microsoft\SqlServer\ComputerManagement16',
        'root\Microsoft\SqlServer\ComputerManagement15',
        'root\Microsoft\SqlServer\ComputerManagement14',
        'root\Microsoft\SqlServer\ComputerManagement13',
        'root\Microsoft\SqlServer\ComputerManagement12',
        'root\Microsoft\SqlServer\ComputerManagement11'
    )
    $found = @()
    foreach ($ns in $candidates) {
        try {
            Get-CimClass -Namespace $ns -ClassName SqlService -ErrorAction Stop | Out-Null
            $found += $ns
        } catch {}
    }
    $found
}

# ---------------------------------------------------------------------------
# SQL-FREE METADATA HELPERS
# Nothing below opens a SQL connection: everything comes from the SQL Server
# WMI provider (ComputerManagement*), the registry, performance-counter WMI
# classes and the file system.
# ---------------------------------------------------------------------------

# Returns @{ Str = @{Name=string}; Num = @{Name=number} } from SqlServiceAdvancedProperty
# (VERSION, SKUNAME, SKU, CLUSTERED, VSNAME, SPLEVEL, DATAPATH, STARTUPPARAMETERS, ...).
function Get-SqlAdvancedProperties {
    param([string]$ServiceName)
    $str = @{}
    $num = @{}
    foreach ($ns in $namespaces) {
        try {
            $filter = "ServiceName='" + $ServiceName + "'"
            $rows = @(Get-CimInstance -Namespace $ns -ClassName SqlServiceAdvancedProperty -Filter $filter -ErrorAction Stop)
            foreach ($r in $rows) {
                $name = [string]$r.PropertyName
                if ($null -ne $r.PropertyNumValue) { $num[$name] = $r.PropertyNumValue }
                if (-not [string]::IsNullOrWhiteSpace([string]$r.PropertyStrValue)) { $str[$name] = [string]$r.PropertyStrValue }
            }
            if ($rows.Count -gt 0) { break }
        } catch {}
    }
    [PSCustomObject]@{ Str = $str; Num = $num }
}

# Per-database sizes from the SQLServer:Databases performance-counter WMI class of the instance.
# Returns rows: Name, DataKB, LogKB, LogUsedKB. Empty when the class is not available.
function Get-SqlDatabasePerf {
    param([string]$InstanceName)
    try {
        $norm = $InstanceName -replace '[^A-Za-z0-9]', '_'
        # Default instance: Win32_PerfFormattedData_MSSQLSERVER_SQLServerDatabases.
        # Named instance:   Win32_PerfFormattedData_MSSQL<NAME>_MSSQL<NAME>Databases (pattern not verified).
        $pattern = '^Win32_PerfFormattedData_(MSSQL)?' + [regex]::Escape($norm) + '_.*Databases$'
        $cls = @(Get-CimClass -Namespace 'root\cimv2' -ClassName 'Win32_PerfFormattedData_*Databases' -ErrorAction Stop |
                    ForEach-Object { $_.CimClassName } |
                    Where-Object { $_ -match $pattern }) | Select-Object -First 1
        if (-not $cls) { return @() }
        @(Get-CimInstance -Namespace 'root\cimv2' -ClassName $cls -ErrorAction Stop |
            Where-Object { $_.Name -ne '_Total' } |
            ForEach-Object {
                [PSCustomObject]@{
                    Name      = [string]$_.Name
                    DataKB    = $_.DataFilesSizeKB
                    LogKB     = $_.LogFilesSizeKB
                    LogUsedKB = $_.LogFilesUsedSizeKB
                }
            })
    } catch { @() }
}

# Fallback when no performance-counter class exists: .mdf/.ndf/.ldf files in the instance's data
# and log directories (real on-disk sizes). Only these directories are scanned, never the whole
# install tree (Binn\Templates holds template .mdf files that are not databases).
function Get-SqlDataFileRows {
    param([string[]]$Directories)
    $special = @{ mastlog = 'master'; modellog = 'model'; msdbdata = 'msdb'; msdblog = 'msdb'; templog = 'tempdb' }
    foreach ($dir in ($Directories | Where-Object { $_ } | Select-Object -Unique)) {
        try {
            Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop |
                Where-Object { $_.Extension -in '.mdf', '.ndf', '.ldf' } |
                ForEach-Object {
                    $isLog = ($_.Extension -eq '.ldf')
                    $base  = $_.BaseName
                    $db    = if ($special.ContainsKey($base.ToLowerInvariant())) { $special[$base.ToLowerInvariant()] }
                             elseif ($isLog) { $base -replace '_log$', '' }
                             else { $base }
                    [PSCustomObject]@{
                        DatabaseName    = $db
                        LogicalFileName = $null
                        FileType        = if ($isLog) { 'LOG' } else { 'ROWS' }
                        PhysicalPath    = $_.FullName
                        SizeMB          = [math]::Round($_.Length / 1MB, 2)
                        UsedMB          = $null
                        growth          = $null
                        IsPercentGrowth = $null
                        MaxSizePages    = $null
                    }
                }
        } catch {}
    }
}

function Get-InstanceName {
    param([string]$ServiceName)
    if ($ServiceName -eq 'MSSQLSERVER') { return 'MSSQLSERVER' }
    if ($ServiceName -match '^MSSQL\$(.+)$') { return $Matches[1] }
    return $ServiceName
}

function Get-InstanceId {
    param([string]$InstanceName)
    $key = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    RegValue $key $InstanceName
}

function Get-RegistryInstanceData {
    param([string]$InstanceId)
    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return $null }
    $base = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$InstanceId\Setup"
    [PSCustomObject]@{
        InstanceId    = $InstanceId
        Edition       = RegValue $base 'Edition'
        EditionType   = RegValue $base 'EditionType'
        Version       = RegValue $base 'Version'
        PatchLevel    = RegValue $base 'PatchLevel'
        CurrentVersion= RegValue $base 'CurrentVersion'
        ProductCode   = RegValue $base 'ProductCode'
        SQLPath       = RegValue $base 'SQLPath'
        SQLBinRoot    = RegValue $base 'SQLBinRoot'
        SQLDataRoot   = RegValue $base 'SQLDataRoot'
        SQLProgramDir = RegValue $base 'SQLProgramDir'
        DefaultData   = RegValue $base 'DefaultData'
        DefaultLog    = RegValue $base 'DefaultLog'
        DefaultBackup = RegValue $base 'DefaultBackup'
    }
}

# ---------------------------------------------------------------------------
# VM INFORMATION
# ---------------------------------------------------------------------------

$computer   = SafeGet { Get-CimInstance Win32_ComputerSystem }
$os         = SafeGet { Get-CimInstance Win32_OperatingSystem }
$bios       = SafeGet { Get-CimInstance Win32_BIOS }
$product    = SafeGet { Get-CimInstance Win32_ComputerSystemProduct }
$processors = @(SafeGet { @(Get-CimInstance Win32_Processor) })

$disks = @(SafeGet {
    @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3")
})

$network = @()
if (-not $SkipNetworkDetails) {
    $network = @(SafeGet {
        @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True")
    })
}

# ---------------------------------------------------------------------------
# SQL WMI DISCOVERY
# ---------------------------------------------------------------------------

$namespaces    = @(Get-SqlNamespaces)
$sqlWmiServices = @()

foreach ($ns in $namespaces) {
    try {
        $sqlWmiServices += @(Get-CimInstance -Namespace $ns -ClassName SqlService -ErrorAction Stop)
    } catch {}
}

# De-duplicate by ServiceName
$sqlWmiServices = @(
    $sqlWmiServices |
        Group-Object ServiceName |
        ForEach-Object { $_.Group | Select-Object -First 1 }
)

# Windows service fallback
$windowsServices = @(SafeGet {
    @(Get-CimInstance Win32_Service |
        Where-Object {
            $_.Name -eq 'MSSQLSERVER'         -or
            $_.Name -like 'MSSQL$*'           -or
            $_.Name -eq 'SQLSERVERAGENT'       -or
            $_.Name -like 'SQLSERVERAGENT$*'   -or
            $_.Name -eq 'SQLBrowser'
        })
})

$engineServices = @(
    $sqlWmiServices | Where-Object {
        $_.ServiceName -eq 'MSSQLSERVER' -or $_.ServiceName -like 'MSSQL$*'
    }
)

if ($engineServices.Count -eq 0) {
    $engineServices = @(
        $windowsServices | Where-Object {
            $_.Name -eq 'MSSQLSERVER' -or $_.Name -like 'MSSQL$*'
        }
    )
}

$instances = @()

foreach ($service in $engineServices) {

    $serviceName = if ($service.PSObject.Properties['ServiceName']) {
        [string]$service.ServiceName
    } else {
        [string]$service.Name
    }

    $instanceName   = Get-InstanceName $serviceName
    $defaultInstance = ($instanceName -eq 'MSSQLSERVER')
    $endpoint        = if ($defaultInstance) { 'localhost' } else { "localhost\$instanceName" }

    $instanceId = Get-InstanceId $instanceName
    $reg        = Get-RegistryInstanceData $instanceId

    $fallbackService = $windowsServices |
        Where-Object Name -eq $serviceName |
        Select-Object -First 1

    $serviceState = if ($service.PSObject.Properties['State']) {
        $service.State
    } elseif ($fallbackService) {
        $fallbackService.State
    } else { $null }

    $startMode = if ($service.PSObject.Properties['StartMode']) {
        $service.StartMode
    } elseif ($fallbackService) {
        $fallbackService.StartMode
    } else { $null }

    $serviceAccount = if ($service.PSObject.Properties['StartAccount']) {
        $service.StartAccount
    } elseif ($fallbackService) {
        $fallbackService.StartName
    } else { $null }

    # -- Engine / database metadata WITHOUT a SQL connection ------------------
    # Sources: SqlServiceAdvancedProperty (WMI), registry, performance-counter WMI
    # classes and data-file sizes. Not available this way (left empty): licence type
    # and count, product update level, cluster/AG/log-shipping/mirroring detail and
    # per-database state, recovery model, compatibility level, owner, creation date,
    # encryption and log reuse wait.
    $engine             = $null
    $sqlConnectionError = $null
    $configuration      = @()
    $databases          = @()
    $databaseFiles      = @()
    $clusterNodes       = @()
    $agReplicas         = @()
    $logShipping        = @()
    $dbMirroring        = @()

    if (-not $SkipDatabaseDetails) {
        try {
            $adv     = Get-SqlAdvancedProperties $serviceName
            $instKey = if ($instanceId) { "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId" } else { $null }
            $setupKey  = if ($instKey) { "$instKey\Setup" } else { $null }
            $serverKey = if ($instKey) { "$instKey\MSSQLServer" } else { $null }

            $version  = if ($adv.Str['VERSION']) { $adv.Str['VERSION'] } elseif ($reg) { $reg.Version } else { $null }
            $edition  = if ($adv.Str['SKUNAME']) { $adv.Str['SKUNAME'] } elseif ($reg) { $reg.Edition } else { $null }

            if ($version -or $edition) {
                $isClustered = if ($adv.Num.ContainsKey('CLUSTERED')) { [int]$adv.Num['CLUSTERED'] } else { 0 }
                $vsName      = $adv.Str['VSNAME']
                $hadr        = if ($serverKey) { RegValue "$serverKey\HADR" 'HADR_Enabled' } else { $null }
                $loginMode   = if ($serverKey) { RegValue $serverKey 'LoginMode' } else { $null }
                $spLevel     = if ($adv.Num.ContainsKey('SPLEVEL')) { [int]$adv.Num['SPLEVEL'] } else { 0 }
                $netName     = if ($isClustered -eq 1 -and $vsName) { $vsName } else { $env:COMPUTERNAME }

                $engine = [PSCustomObject]@{
                    ServerName               = if ($defaultInstance) { $netName } else { "$netName\$instanceName" }
                    MachineName              = $env:COMPUTERNAME
                    InstanceName             = if ($defaultInstance) { $null } else { $instanceName }
                    Edition                  = $edition
                    EditionID                = if ($adv.Num.ContainsKey('SKU')) { $adv.Num['SKU'] } else { $null }
                    ProductVersion           = $version
                    ProductLevel             = if ($spLevel -gt 0) { "SP$spLevel" } else { 'RTM' }
                    ProductUpdateLevel       = $null
                    ProductUpdateReference   = $null
                    EngineEdition            = $null
                    IsClustered              = $isClustered
                    IsHadrEnabled            = if ($null -ne $hadr) { [int]$hadr } else { $null }
                    IsIntegratedSecurityOnly = if ($null -ne $loginMode) { if ([int]$loginMode -eq 1) { 1 } else { 0 } } else { $null }
                    ServerCollation          = if ($setupKey) { RegValue $setupKey 'Collation' } else { $null }
                    ResourceVersion          = $null
                    LicenseType              = $null
                    NumLicenses              = $null
                    PhysicalNetBIOSName      = $env:COMPUTERNAME
                }

                # Failover cluster nodes (best effort; only when the cluster WMI provider is present).
                # This node is reported as the owner because the instance is running on it.
                if ($isClustered -eq 1) {
                    $clusterNodes = @(SafeGet {
                        @(Get-CimInstance -Namespace 'root\MSCluster' -ClassName MSCluster_Node -ErrorAction Stop |
                            ForEach-Object {
                                [PSCustomObject]@{
                                    NodeName       = [string]$_.Name
                                    NodeStatus     = switch ([int]$_.State) { 0 { 'UP' } 1 { 'DOWN' } 2 { 'PAUSED' } 3 { 'JOINING' } default { 'UNKNOWN' } }
                                    IsCurrentOwner = [int](([string]$_.Name -ieq $env:COMPUTERNAME) -and ([string]$serviceState -in @('Running', '4')))
                                }
                            })
                    })
                }

                # Directories that hold the instance's database files.
                $startup = [string]$adv.Str['STARTUPPARAMETERS']
                $dirs = @()
                if ($startup -match '(?i)(?:^|;)-d([^;]+)') { $dirs += (Split-Path -Parent $Matches[1]) }
                if ($startup -match '(?i)(?:^|;)-l([^;]+)') { $dirs += (Split-Path -Parent $Matches[1]) }
                if ($adv.Str['DATAPATH']) { $dirs += $adv.Str['DATAPATH'] }
                if ($serverKey) {
                    $dirs += (RegValue $serverKey 'DefaultData')
                    $dirs += (RegValue $serverKey 'DefaultLog')
                }
                if ($reg -and $reg.SQLDataRoot) { $dirs += (Join-Path $reg.SQLDataRoot 'DATA') }

                $perf  = @(Get-SqlDatabasePerf $instanceName)
                $files = @(Get-SqlDataFileRows $dirs)

                $dbNames = if ($perf.Count -gt 0) { @($perf | ForEach-Object { $_.Name }) }
                           else { @($files | ForEach-Object { $_.DatabaseName } | Select-Object -Unique) }
                $dbNames = @($dbNames | Sort-Object -Unique)

                foreach ($dbName in $dbNames) {
                    $databases += [PSCustomObject]@{
                        database_id          = $null
                        DatabaseName         = $dbName
                        State                = $null
                        UserAccess           = $null
                        RecoveryModel        = $null
                        CompatibilityLevel   = $null
                        IsReadOnly           = $null
                        AutoClose            = $null
                        AutoShrink           = $null
                        ServiceBrokerEnabled = $null
                        Trustworthy          = $null
                        DbChaining           = $null
                        Encrypted            = $null
                        QueryStoreEnabled    = $null
                        Containment          = $null
                        CreateDate           = $null
                        OwnerName            = $null
                        LogReuseWait         = $null
                    }

                    $dbPerf  = $perf | Where-Object { $_.Name -eq $dbName } | Select-Object -First 1
                    $dbFiles = @($files | Where-Object { $_.DatabaseName -ieq $dbName })
                    if ($dbFiles.Count -gt 0) {
                        $logRows = @($dbFiles | Where-Object { $_.FileType -eq 'LOG' })
                        if ($dbPerf -and $null -ne $dbPerf.LogUsedKB -and $logRows.Count -eq 1) {
                            $logRows[0].UsedMB = [math]::Round([double]$dbPerf.LogUsedKB / 1024, 2)
                        }
                        $databaseFiles += $dbFiles
                    } elseif ($dbPerf) {
                        # No file found on disk (e.g. files in another directory): use the counter sizes.
                        $databaseFiles += [PSCustomObject]@{
                            DatabaseName = $dbName; LogicalFileName = $null; FileType = 'ROWS'; PhysicalPath = $null
                            SizeMB = [math]::Round([double]$dbPerf.DataKB / 1024, 2); UsedMB = $null
                            growth = $null; IsPercentGrowth = $null; MaxSizePages = $null
                        }
                        $databaseFiles += [PSCustomObject]@{
                            DatabaseName = $dbName; LogicalFileName = $null; FileType = 'LOG'; PhysicalPath = $null
                            SizeMB = [math]::Round([double]$dbPerf.LogKB / 1024, 2)
                            UsedMB = if ($null -ne $dbPerf.LogUsedKB) { [math]::Round([double]$dbPerf.LogUsedKB / 1024, 2) } else { $null }
                            growth = $null; IsPercentGrowth = $null; MaxSizePages = $null
                        }
                    }
                }
            } else {
                $sqlConnectionError = 'SQL Server WMI provider and registry returned no version or edition for this instance.'
            }
        } catch {
            $sqlConnectionError = $_.Exception.Message
        }
    }

    # TCP configuration from registry
    $tcp = $null
    try {
        if ($instanceId) {
            $tcpKey  = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer\SuperSocketNetLib\Tcp"
            $ipAll   = Join-Path $tcpKey 'IPAll'
            $tcp = [PSCustomObject]@{
                Enabled      = RegValue $tcpKey 'Enabled'
                Port         = RegValue $ipAll  'TcpPort'
                DynamicPorts = RegValue $ipAll  'TcpDynamicPorts'
            }
        }
    } catch {}

    $agentName = if ($defaultInstance) { 'SQLSERVERAGENT' } else { 'SQLSERVERAGENT$' + $instanceName }
    $agent     = $windowsServices | Where-Object Name -eq $agentName | Select-Object -First 1
    $browser   = $windowsServices | Where-Object Name -eq 'SQLBrowser' | Select-Object -First 1

    $instances += [PSCustomObject]@{
        ServiceName      = $serviceName
        InstanceName     = $instanceName
        IsDefaultInstance= $defaultInstance
        Endpoint         = $endpoint

        ServiceDisplayName = if ($service.PSObject.Properties['DisplayName']) {
            $service.DisplayName
        } elseif ($fallbackService) {
            $fallbackService.DisplayName
        } else { $serviceName }

        ServiceState     = $serviceState
        ServiceStartMode = $startMode
        ServiceAccount   = $serviceAccount

        SQLAgentState    = if ($agent)   { $agent.State   } else { $null }
        SQLBrowserState  = if ($browser) { $browser.State } else { $null }

        InstanceId         = $instanceId
        RegistryEdition    = if ($reg) { $reg.Edition    } else { $null }
        RegistryVersion    = if ($reg) { $reg.Version    } else { $null }
        PatchLevel         = if ($reg) { $reg.PatchLevel } else { $null }
        SQLPath            = if ($reg) { $reg.SQLPath    } else { $null }
        SQLDataRoot        = if ($reg) { $reg.SQLDataRoot    } else { $null }
        DefaultDataPath    = if ($reg) { $reg.DefaultData    } else { $null }
        DefaultLogPath     = if ($reg) { $reg.DefaultLog     } else { $null }
        DefaultBackupPath  = if ($reg) { $reg.DefaultBackup  } else { $null }

        ServerName              = if ($engine) { $engine.ServerName    } else { $null }
        MachineName             = if ($engine) { $engine.MachineName   } else { $null }
        SQLInstanceName         = if ($engine) { $engine.InstanceName  } else { $instanceName }
        Edition                 = if ($engine) { $engine.Edition       } else { $null }
        EditionID               = if ($engine) { $engine.EditionID     } else { $null }
        ProductVersion          = if ($engine) { $engine.ProductVersion } else { $null }
        ProductLevel            = if ($engine) { $engine.ProductLevel   } else { $null }
        ProductUpdateLevel      = if ($engine) { $engine.ProductUpdateLevel     } else { $null }
        ProductUpdateReference  = if ($engine) { $engine.ProductUpdateReference } else { $null }
        EngineEdition           = if ($engine) { $engine.EngineEdition    } else { $null }
        IsClustered             = if ($engine) { $engine.IsClustered      } else { $null }
        IsHadrEnabled           = if ($engine) { $engine.IsHadrEnabled    } else { $null }
        WindowsAuthenticationOnly = if ($engine) { $engine.IsIntegratedSecurityOnly } else { $null }
        ServerCollation         = if ($engine) { $engine.ServerCollation  } else { $null }
        ResourceVersion         = if ($engine) { $engine.ResourceVersion  } else { $null }

        TCP               = $tcp
        # No SQL connection is made. SQLConnectionOK now means "engine metadata collected via WMI/registry":
        # $null  = collection skipped (-SkipDatabaseDetails)
        # $true  = metadata collected
        # $false = WMI/registry returned nothing for this instance
        SQLConnectionOK   = if ($SkipDatabaseDetails) { $null } else { [bool]$engine }
        SQLConnectionError= $sqlConnectionError

        # -- Licensing -----------------------------------------------------
        # Licence type and count are only exposed by SERVERPROPERTY (needs a SQL connection),
        # so they are left empty. The edition string above identifies Evaluation / Developer / Express.
        LicenseType       = if ($engine) { $engine.LicenseType  } else { $null }
        NumLicenses       = if ($engine) { $engine.NumLicenses  } else { $null }

        # -- Cluster -------------------------------------------------------
        # ClusterName is the virtual network name of the FCI.
        # PhysicalNetBIOSName is the physical node name (same as MachineName
        # on standalone; differs from ServerName on a clustered instance).
        ClusterName       = if ($engine -and $engine.IsClustered -eq 1) {
                                # Virtual name = ServerName minus instance suffix
                                ($engine.ServerName -replace '\\.*$', '')
                            } else { $null }
        PhysicalNetBIOSName = if ($engine) { $engine.PhysicalNetBIOSName } else { $null }
        ClusterNodes      = $clusterNodes   # rows: NodeName, NodeStatus, IsCurrentOwner

        # -- Always On AG -------------------------------------------------
        AGReplicas        = $agReplicas     # rows: AGName, ReplicaServer, ReplicaRole, etc.

        # Convenience: this instance's own AG role (PRIMARY / SECONDARY / RESOLVING)
        # and whether it is a readable secondary.
        # Match on physical node name first; on an FCI the ReplicaServer may be the
        # virtual network name, so also try the ClusterName as a fallback.
        AGLocalRole       = if (@($agReplicas).Count -gt 0) {
                                $self = $agReplicas | Where-Object {
                                    $_.ReplicaServer -like "$env:COMPUTERNAME*" -or
                                    ($engine -and $engine.PhysicalNetBIOSName -and
                                     $_.ReplicaServer -like "$($engine.PhysicalNetBIOSName)*") -or
                                    ($engine -and $engine.IsClustered -eq 1 -and
                                     $_.ReplicaServer -like "$(($engine.ServerName -replace '\\.*$',''))*")
                                } | Select-Object -First 1
                                if ($self) { [string]$self.ReplicaRole } else { $null }
                            } else { $null }

        AGReadableSecondary = if (@($agReplicas).Count -gt 0) {
                                  $self = $agReplicas | Where-Object {
                                      $_.ReplicaServer -like "$env:COMPUTERNAME*" -or
                                      ($engine -and $engine.PhysicalNetBIOSName -and
                                       $_.ReplicaServer -like "$($engine.PhysicalNetBIOSName)*") -or
                                      ($engine -and $engine.IsClustered -eq 1 -and
                                       $_.ReplicaServer -like "$(($engine.ServerName -replace '\\.*$',''))*")
                                  } | Select-Object -First 1
                                  if ($self) { [string]$self.SecondaryReadAccess } else { $null }
                              } else { $null }

        # -- Passive instance detection (non-cluster) ----------------------
        # IsLogShippingSecondary: true when this instance hosts at least one
        # log-shipping secondary database.
        IsLogShippingSecondary = (@($logShipping).Count -gt 0)
        LogShippingDatabases   = $logShipping   # detail rows

        # IsMirroringMirror: true when any database is in MIRROR role.
        IsMirroringMirror = @($dbMirroring | Where-Object { $_.MirroringRole -eq 'MIRROR' }).Count -gt 0
        MirroringDatabases = $dbMirroring   # detail rows

        Configuration  = $configuration
        Databases      = $databases
        DatabaseFiles  = $databaseFiles
    }
}

# ---------------------------------------------------------------------------
# ORACLE DISCOVERY
# ---------------------------------------------------------------------------

$oracleInstances = @()

# --- 1. Registry: HKLM:\SOFTWARE\ORACLE enumerates all Oracle homes ---
$oracleHomes = @()
try {
    $oracleBaseKey = 'HKLM:\SOFTWARE\ORACLE'
    if (Test-Path -LiteralPath $oracleBaseKey) {
        $oracleHomes = @(
            Get-ChildItem -LiteralPath $oracleBaseKey -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like 'KEY_*' } |
            ForEach-Object {
                $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                if ($props -and $props.PSObject.Properties['ORACLE_HOME']) {
                    [PSCustomObject]@{
                        HomeKey     = $_.PSChildName
                        OracleHome  = [string]$props.ORACLE_HOME
                        OracleSid   = if ($props.PSObject.Properties['ORACLE_SID'])  { [string]$props.ORACLE_SID  } else { '' }
                        OracleBase  = if ($props.PSObject.Properties['ORACLE_BASE']) { [string]$props.ORACLE_BASE } else { '' }
                        NlsLang     = if ($props.PSObject.Properties['NLS_LANG'])    { [string]$props.NLS_LANG    } else { '' }
                        Version     = if ($props.PSObject.Properties['ORACLE_HOME_VERSION']) { [string]$props.ORACLE_HOME_VERSION } else { '' }
                    }
                }
            }
        )
    }
} catch {}

# --- 2. Windows Services: OracleService* = DB instances, OracleOra*TNSListener* = listeners ---
$oracleServices = @(SafeGet {
    @(Get-CimInstance Win32_Service |
        Where-Object {
            $_.Name -like 'OracleService*'     -or
            $_.Name -like 'OracleOra*TNS*'     -or
            $_.Name -like 'OracleOra*Listener*' -or
            $_.Name -like 'OracleListener*'
        })
})

$oracleDbServices  = @($oracleServices | Where-Object { $_.Name -like 'OracleService*' })
$oracleListeners   = @($oracleServices | Where-Object { $_.Name -notlike 'OracleService*' })

# --- 3. Synthetic service objects from registry when no OracleService* services found ---
# Some Oracle installations (especially manual/silent installs) register the DB in the
# registry and create a listener service but omit the OracleService<SID> Windows service.
# Fall back: create a synthetic entry per ORACLE_SID found in registry homes.
if ($oracleDbServices.Count -eq 0 -and @($oracleHomes).Count -gt 0) {
    $oracleDbServices = @(
        $oracleHomes | Where-Object { $_.OracleSid -ne '' } | ForEach-Object {
            [PSCustomObject]@{
                Name      = 'OracleService' + $_.OracleSid
                State     = 'Unknown'   # service not registered - assume DB may be accessible
                StartMode = 'Unknown'
                IsSynthetic = $true
            }
        }
    )
}

# --- 4. Per-instance collection ---
foreach ($svc in $oracleDbServices) {
    # SID = name after 'OracleService' prefix
    $sid = $svc.Name -replace '^OracleService', ''

    # Find matching home from registry (by SID or fall back to first home)
    # Note: $home is a PS automatic variable - use $oraHome to avoid conflict
    $oraHome = $oracleHomes | Where-Object { $_.OracleSid -eq $sid } | Select-Object -First 1
    if (-not $oraHome) { $oraHome = $oracleHomes | Select-Object -First 1 }

    $oracleHomePath = if ($oraHome) { $oraHome.OracleHome } else { '' }
    $oracleVersion  = if ($oraHome) { $oraHome.Version    } else { '' }
    $oracleBase     = if ($oraHome) { $oraHome.OracleBase  } else { '' }

    # Try to get version from sqlplus -v if registry version is blank
    if (-not $oracleVersion -and $oracleHomePath) {
        try {
            $sqlplusExe = Join-Path $oracleHomePath 'bin\sqlplus.exe'
            if (Test-Path -LiteralPath $sqlplusExe) {
                $verOut = & $sqlplusExe -v 2>&1 | Select-Object -First 5
                $verLine = $verOut | Where-Object { $_ -match 'Release\s+([\d\.]+)' } | Select-Object -First 1
                if ($verLine -match 'Release\s+([\d\.]+)') { $oracleVersion = $Matches[1] }
            }
        } catch {}
    }

    # Listener port - scan listener.ora or query lsnrctl
    $listenerPort = ''
    $listenerName = ''
    try {
        # Find listener.ora in ORACLE_HOME\network\admin
        $lsnrOra = Join-Path $oracleHomePath 'network\admin\listener.ora'
        if (Test-Path -LiteralPath $lsnrOra) {
            $lsnrContent = Get-Content -LiteralPath $lsnrOra -ErrorAction SilentlyContinue
            $portLine = $lsnrContent | Where-Object { $_ -match 'PORT\s*=\s*(\d+)' } | Select-Object -First 1
            if ($portLine -match 'PORT\s*=\s*(\d+)') { $listenerPort = $Matches[1] }
            $nameLine = $lsnrContent | Where-Object { $_ -match '^\s*([A-Z_]+)\s*=' } | Select-Object -First 1
            if ($nameLine -match '^\s*([A-Z_]+)\s*=') { $listenerName = $Matches[1] }
        }
    } catch {}
    if (-not $listenerPort) { $listenerPort = '1521' }   # Oracle default

    # Matching listener service
    $lsnrSvc = $oracleListeners | Select-Object -First 1

    # Query Oracle via SQL*Plus (runs as current user on the target VM)
    $oraDbRows    = @()
    $oraDbError   = $null
    $oraConnOK    = $false
    if ($oracleHomePath -and ($svc.State -eq 'Running' -or $svc.State -eq 'Unknown')) {
        try {
            $sqlplusExe = Join-Path $oracleHomePath 'bin\sqlplus.exe'
            if (Test-Path -LiteralPath $sqlplusExe) {

                $env:ORACLE_HOME     = $oracleHomePath
                $env:ORACLE_SID      = $sid
                $env:PATH            = "$oracleHomePath\bin;$env:PATH"
                $env:NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS'

                # --- Query 1: v$version + v$instance - edition, full version, license ---
                $verQuery = @"
SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SET LINESIZE 512
SELECT
    NVL(v.banner,'')        ||'|'||
    NVL(i.version,'')       ||'|'||
    NVL(i.edition,'')       ||'|'||
    NVL(i.host_name,'')     ||'|'||
    NVL(i.instance_name,'') ||'|'||
    NVL(i.status,'')
FROM v`$instance i,
     (SELECT banner FROM v`$version
      WHERE banner LIKE 'Oracle Database%'
      AND ROWNUM = 1) v;
EXIT;
"@
                $tmpVer = [System.IO.Path]::GetTempFileName() -replace '\.tmp$','.sql'
                [System.IO.File]::WriteAllText($tmpVer, $verQuery, [System.Text.Encoding]::ASCII)
                $verOut = & $sqlplusExe -S '/ as sysdba' "@$tmpVer" 2>&1
                Remove-Item -LiteralPath $tmpVer -ErrorAction SilentlyContinue

                $oraEdition      = ''
                $oraVersionBanner= ''
                $oraVersionFull  = ''
                $oraHostName     = ''
                $oraInstanceName = ''
                $oraStatus       = ''
                foreach ($line in $verOut) {
                    $l = [string]$line
                    if ($l -match '\|') {
                        $cols = $l -split '\|'
                        if ($cols.Count -ge 6) {
                            $oraVersionBanner = $cols[0].Trim()
                            $oraVersionFull   = $cols[1].Trim()
                            $oraEdition       = $cols[2].Trim()
                            $oraHostName      = $cols[3].Trim()
                            $oraInstanceName  = $cols[4].Trim()
                            $oraStatus        = $cols[5].Trim()
                            break
                        }
                    }
                }

                # Derive edition label from banner when v$instance.edition is blank
                # Banner examples:
                #   "Oracle Database 21c Enterprise Edition Release 21.0.0.0.0 ..."
                #   "Oracle Database 21c Express Edition Release 21.0.0.0.0 ..."
                if (-not $oraEdition -and $oraVersionBanner) {
                    if     ($oraVersionBanner -match 'Enterprise') { $oraEdition = 'Enterprise Edition' }
                    elseif ($oraVersionBanner -match 'Standard.*2')  { $oraEdition = 'Standard Edition 2' }
                    elseif ($oraVersionBanner -match 'Standard')  { $oraEdition = 'Standard Edition' }
                    elseif ($oraVersionBanner -match 'Express')   { $oraEdition = 'Express Edition (XE)' }
                    elseif ($oraVersionBanner -match 'Personal')  { $oraEdition = 'Personal Edition' }
                    else                                           { $oraEdition = 'Unknown' }
                }

                # Derive license type from edition
                $oraLicense = switch -Wildcard ($oraEdition) {
                    '*Enterprise*' { 'Named User Plus or Processor' }
                    '*Standard 2*' { 'Named User Plus or Processor (max 2 sockets)' }
                    '*Standard*'   { 'Named User Plus or Processor' }
                    '*Express*'    { 'Free (XE)' }
                    '*Personal*'   { 'Personal (single user)' }
                    default        { '' }
                }

                # Use version from v$instance if registry version was blank
                if (-not $oracleVersion -and $oraVersionFull) { $oracleVersion = $oraVersionFull }

                # Mark connection OK as soon as Query 1 parses - Edition/Version/Banner
                # are now safe to store regardless of whether Query 2 succeeds below.
                if ($oraVersionBanner -or $oraEdition -or $oraVersionFull) {
                    $oraConnOK = $true
                }

                # --- Query 2: v$database + v$pdbs - DB name, open mode, CDB/PDB info ---
                $sqlQuery = @"
SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SET LINESIZE 512
SELECT
    d.name                                              ||'|'||
    d.db_unique_name                                    ||'|'||
    d.open_mode                                         ||'|'||
    d.log_mode                                          ||'|'||
    d.cdb                                               ||'|'||
    NVL(TO_CHAR(d.created,'YYYY-MM-DD HH24:MI:SS'),'') ||'|'||
    d.platform_name                                     ||'|'||
    d.db_version                                        ||'|'||
    NVL(p.pdb_name,'')                                  ||'|'||
    NVL(p.open_mode,'')
FROM v`$database d
LEFT JOIN (
    SELECT pdb_name, open_mode FROM v`$pdbs WHERE pdb_name <> 'PDB`$SEED'
) p ON 1=1;
EXIT;
"@
                $tmpSql = [System.IO.Path]::GetTempFileName() -replace '\.tmp$','.sql'
                [System.IO.File]::WriteAllText($tmpSql, $sqlQuery, [System.Text.Encoding]::ASCII)
                $rawOut = & $sqlplusExe -S '/ as sysdba' "@$tmpSql" 2>&1
                Remove-Item -LiteralPath $tmpSql -ErrorAction SilentlyContinue

                # Parse pipe-delimited rows
                $parsedRows = @()
                foreach ($line in $rawOut) {
                    $l = [string]$line
                    if ($l -match '\|') {
                        $cols = $l -split '\|'
                        if ($cols.Count -ge 8) {
                            $parsedRows += [PSCustomObject]@{
                                DBName        = $cols[0].Trim()
                                DBUniqueName  = $cols[1].Trim()
                                OpenMode      = $cols[2].Trim()
                                LogMode       = $cols[3].Trim()
                                IsCDB         = $cols[4].Trim()
                                CreatedDate   = $cols[5].Trim()
                                Platform      = $cols[6].Trim()
                                DBVersion     = $cols[7].Trim()
                                PDBName       = if ($cols.Count -gt 8) { $cols[8].Trim() } else { '' }
                                PDBOpenMode   = if ($cols.Count -gt 9) { $cols[9].Trim() } else { '' }
                            }
                        }
                    }
                }
                $oraDbRows = $parsedRows
                $oraConnOK = $true   # also set here in case Query 1 produced no banner
            }
        } catch {
            $oraDbError = $_.Exception.Message
        }
    }

    # Datafile sizes from v$datafile (best-effort, same SQL*Plus session pattern)
    $oraDatafiles = @()
    if ($oraConnOK -and $oracleHomePath) {
        try {
            $sqlplusExe = Join-Path $oracleHomePath 'bin\sqlplus.exe'
            $dfQuery = @"
SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SET LINESIZE 512
SET COLSEP '|'
SELECT
    name                                                        ||'|'||
    NVL(TO_CHAR(ROUND(bytes/1073741824,2)),'0')                 ||'|'||
    status
FROM v`$datafile
ORDER BY name;
EXIT;
"@
            $tmpDf = [System.IO.Path]::GetTempFileName() -replace '\.tmp$','.sql'
            [System.IO.File]::WriteAllText($tmpDf, $dfQuery, [System.Text.Encoding]::ASCII)
            $dfOut = & $sqlplusExe -S '/ as sysdba' "@$tmpDf" 2>&1
            Remove-Item -LiteralPath $tmpDf -ErrorAction SilentlyContinue
            foreach ($line in $dfOut) {
                $l = [string]$line
                if ($l -match '\|') {
                    $cols = $l -split '\|'
                    if ($cols.Count -ge 3) {
                        $oraDatafiles += [PSCustomObject]@{
                            FileName  = $cols[0].Trim()
                            SizeGB    = $cols[1].Trim()
                            Status    = $cols[2].Trim()
                        }
                    }
                }
            }
        } catch {}
    }

    $_mSize          = $oraDatafiles | ForEach-Object { [double]$_.SizeGB } | Measure-Object -Sum
    $totalDataSizeGB = [double]$(if ($null -ne $_mSize.Sum) { $_mSize.Sum } else { 0 })

    $oracleInstances += [PSCustomObject]@{
        SID              = $sid
        ServiceName      = [string]$svc.Name
        ServiceState     = [string]$svc.State
        ServiceStartMode = [string]$svc.StartMode
        OracleHome       = $oracleHomePath
        OracleBase       = $oracleBase
        Version          = $oracleVersion
        VersionBanner    = if ($oraConnOK) { $oraVersionBanner } else { '' }
        Edition          = if ($oraConnOK) { $oraEdition       } else { '' }
        License          = if ($oraConnOK) { $oraLicense       } else { '' }
        ProductLevel     = if ($oraConnOK) { $oraStatus        } else { '' }
        InstanceName     = if ($oraConnOK) { $oraInstanceName  } else { $sid }
        HostName         = if ($oraConnOK) { $oraHostName      } else { '' }
        ListenerPort     = $listenerPort
        ListenerName     = $listenerName
        ListenerState    = if ($lsnrSvc) { [string]$lsnrSvc.State } else { '' }
        ConnectString    = "localhost:$listenerPort/$sid"
        OracleConnOK     = $oraConnOK
        OracleConnError  = $oraDbError
        Databases        = $oraDbRows
        Datafiles        = $oraDatafiles
        TotalDataSizeGB  = [math]::Round($totalDataSizeGB, 2)
        DatabaseCount    = [int]@($oraDbRows).Count
    }
}

# ---------------------------------------------------------------------------
# RETURN OBJECT
# ---------------------------------------------------------------------------

[PSCustomObject]@{
    CollectionStatus = 'Success'
    CollectionTime   = (Get-Date).ToUniversalTime().ToString('o')

    VM = [PSCustomObject]@{
        ComputerName    = [string]$env:COMPUTERNAME
        Domain          = SafeGet { $computer.Domain }
        PartOfDomain    = SafeGet { $computer.PartOfDomain }
        Manufacturer    = SafeGet { $computer.Manufacturer }
        Model           = SafeGet { $computer.Model }
        SystemType      = SafeGet { $computer.SystemType }
        TotalPhysicalMemoryGB = if ($computer) {
            [math]::Round([double]$computer.TotalPhysicalMemory / 1GB, 2)
        } else { $null }
        NumberOfProcessors    = SafeGet { $computer.NumberOfProcessors }
        LogicalProcessorCount = if ($processors.Count -gt 0) {
            ($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        } else {
            SafeGet { $computer.NumberOfLogicalProcessors }
        }
        PhysicalCoreCount = if ($processors.Count -gt 0) {
            ($processors | Measure-Object -Property NumberOfCores -Sum).Sum
        } else { $null }
        ProcessorNames  = @($processors | ForEach-Object { [string]$_.Name })
        OS              = SafeGet { $os.Caption }
        OSVersion       = SafeGet { $os.Version }
        OSBuild         = SafeGet { $os.BuildNumber }
        OSArchitecture  = SafeGet { $os.OSArchitecture }
        InstallDate     = SafeGet { $os.InstallDate }
        LastBootUpTime  = SafeGet { $os.LastBootUpTime }
        SerialNumber    = SafeGet { $bios.SerialNumber }
        BIOSVersion     = if ($bios) { @($bios.SMBIOSBIOSVersion) -join ', ' } else { $null }
        UUID            = SafeGet { $product.UUID }
    }

    Disks = @($disks | ForEach-Object {
        [PSCustomObject]@{
            Drive       = [string]$_.DeviceID
            VolumeName  = [string]$_.VolumeName
            FileSystem  = [string]$_.FileSystem
            SizeGB      = if ($_.Size)      { [math]::Round([double]$_.Size / 1GB, 2) }      else { 0 }
            FreeGB      = if ($_.FreeSpace) { [math]::Round([double]$_.FreeSpace / 1GB, 2) } else { 0 }
            FreePercent = if ($_.Size -gt 0) {
                [math]::Round(([double]$_.FreeSpace / [double]$_.Size) * 100, 2)
            } else { $null }
        }
    })

    Network = @($network | ForEach-Object {
        [PSCustomObject]@{
            Description = [string]$_.Description
            MACAddress  = [string]$_.MACAddress
            IPAddress   = @($_.IPAddress)
            Gateway     = @($_.DefaultIPGateway)
            DNSServers  = @($_.DNSServerSearchOrder)
        }
    })

    SQLWMI = [PSCustomObject]@{
        NamespacesFound = @($namespaces)
        Services = @($sqlWmiServices | ForEach-Object {
            [PSCustomObject]@{
                ServiceName = if ($_.PSObject.Properties['ServiceName']) { [string]$_.ServiceName } else { $null }
                DisplayName = if ($_.PSObject.Properties['DisplayName']) { [string]$_.DisplayName } else { $null }
                State       = if ($_.PSObject.Properties['State'])       { [string]$_.State       } else { $null }
                StartMode   = if ($_.PSObject.Properties['StartMode'])   { [string]$_.StartMode   } else { $null }
            }
        })
    }

    SQLInstances    = $instances
    OracleInstances = $oracleInstances
}
'@

$RemoteCollector = [scriptblock]::Create($RemoteCollectorSource)

# ---------------------------------------------------------------------------
# LINUX REMOTE COLLECTOR
# Produces the identical return object as the Windows collector so all
# downstream processing (JSON, CSV, HTML) works without any changes.
#
# Transport: PowerShell Remoting over SSH (Invoke-Command -HostName).
# Requires:  PowerShell 7+ on the management machine AND on the Linux target.
#            openssh-server + sshd configured for PS remoting on the target.
#
# Hardware:  /proc/cpuinfo, /proc/meminfo, uname, hostnamectl
# Disks:     df -BG (mounted filesystems)
# Network:   ip addr show
# SQL disc.: systemctl list-units, mssql-conf get-all
# SQL meta:  package manager (version), errorlog (edition), data-directory files (sizes) - no SQL login
# Oracle:    /etc/oratab, $ORACLE_HOME/network/admin/listener.ora, sqlplus
# ---------------------------------------------------------------------------

$LinuxCollectorSource = @'
$SkipDatabaseDetails = ($args[0] -eq '1')
$SkipNetworkDetails  = ($args[1] -eq '1')

# No Set-StrictMode inside the Linux collector - SafeRun handles all errors.
$ErrorActionPreference = 'Continue'

function SafeRun {
    param([scriptblock]$Code)
    try { & $Code } catch { $null }
}

# Run a bash command and return stdout as a trimmed string.
function ShellOut {
    param([string]$Cmd)
    try {
        $out = & /bin/bash -c $Cmd 2>/dev/null
        return ([string]($out -join "`n")).Trim()
    } catch { return '' }
}

# ---------------------------------------------------------------------------
# VM INFORMATION - Linux /proc and system commands
# ---------------------------------------------------------------------------

# OS / hostname - ShellOut already trims; no .Trim() on SafeRun result (may be $null)
$osCaption    = ShellOut 'hostnamectl 2>/dev/null | grep "Operating System" | cut -d: -f2- | sed "s/^ //"'
if (-not $osCaption) {
    $osCaption = ShellOut 'grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d "\""'
}
if (-not $osCaption) { $osCaption = ShellOut 'uname -s -r' }
$osVersion    = ShellOut 'uname -r'
$osBuild      = ShellOut 'uname -v'
$osArch       = ShellOut 'uname -m'
$hostname     = ShellOut 'hostname -f 2>/dev/null || hostname'

# CPU
$cpuInfoRaw   = SafeRun { ShellOut 'cat /proc/cpuinfo' }
$cpuLines     = if ($cpuInfoRaw) { $cpuInfoRaw -split "`n" } else { @() }
$physicalIds  = @($cpuLines | Where-Object { $_ -match '^physical id\s*:' } | ForEach-Object { ($_ -split ':')[1].Trim() } | Sort-Object -Unique)
$coreIds      = @($cpuLines | Where-Object { $_ -match '^core id\s*:' }     | ForEach-Object { ($_ -split ':')[1].Trim() })
$logicalCount = @($cpuLines | Where-Object { $_ -match '^processor\s*:' }).Count
$socketCount  = [math]::Max(1, $physicalIds.Count)
$physCoreCount= [math]::Max(1, ($coreIds | Sort-Object -Unique).Count)
$cpuModel     = ($cpuLines | Where-Object { $_ -match '^model name\s*:' } | Select-Object -First 1) -replace '^model name\s*:\s*',''
$cpuMHz       = ($cpuLines | Where-Object { $_ -match '^cpu MHz\s*:'     } | Select-Object -First 1) -replace '^cpu MHz\s*:\s*',''
$hyperThread  = if ($logicalCount -gt 0 -and $physCoreCount -gt 0) { [math]::Round($logicalCount / $physCoreCount, 1) } else { 1 }

# Memory - /proc/meminfo (kB)
$memInfoRaw   = SafeRun { ShellOut 'cat /proc/meminfo' }
$memTotalKB   = 0
if ($memInfoRaw) {
    $memLine = $memInfoRaw -split "`n" | Where-Object { $_ -match '^MemTotal:' } | Select-Object -First 1
    if ($memLine -match '(\d+)') { $memTotalKB = [long]$Matches[1] }
}
$memTotalGB   = [math]::Round($memTotalKB / 1048576, 2)

# Disks - df -BG for mounted filesystems (type ext4/xfs/btrfs/vfat)
$disks = @()
try {
    $dfOut = ShellOut "df -BG --output=source,fstype,size,avail,target 2>/dev/null | grep -v '^Filesystem' | grep -v '^tmpfs' | grep -v '^devtmpfs' | grep -v '^udev'"
    foreach ($line in ($dfOut -split "`n" | Where-Object { $_.Trim() })) {
        $parts = $line -split '\s+' | Where-Object { $_.Trim() }
        if ($parts.Count -ge 5) {
            $sizeGB  = [double](($parts[2] -replace 'G','').Trim())
            $freeGB  = [double](($parts[3] -replace 'G','').Trim())
            $usedGB  = $sizeGB - $freeGB
            $freePct = if ($sizeGB -gt 0) { [math]::Round(($freeGB / $sizeGB) * 100, 1) } else { 0 }
            $disks += [PSCustomObject]@{
                Drive      = $parts[4]
                VolumeName = $parts[0]
                FileSystem = $parts[1]
                SizeGB     = [math]::Round($sizeGB, 2)
                FreeGB     = [math]::Round($freeGB, 2)
                FreePercent= $freePct
            }
        }
    }
} catch {}

# Network - ip addr
$network = @()
if (-not $SkipNetworkDetails) {
    try {
        $ipOut = ShellOut "ip -o addr show | grep 'inet ' | awk '{print \$2,\$4}'"
        foreach ($line in ($ipOut -split "`n" | Where-Object { $_.Trim() })) {
            $parts = $line -split '\s+'
            if ($parts.Count -ge 2) {
                $network += [PSCustomObject]@{
                    InterfaceAlias = $parts[0]
                    IPAddress      = ($parts[1] -split '/')[0]
                    SubnetPrefix   = ($parts[1] -split '/')[1]
                }
            }
        }
    } catch {}
}

# ---------------------------------------------------------------------------
# SQL SERVER DISCOVERY - systemctl + mssql-conf
# ---------------------------------------------------------------------------

$instances     = @()

# Find all mssql-server engine unit files (default + named instances)
# Default:  mssql-server.service
# Named:    mssql-server-<instancename>.service  (SQL Server 2019+ on Linux)
$sqlUnitNames = @(SafeRun {
    @((ShellOut "systemctl list-units --type=service --all --no-legend 2>/dev/null | grep -E 'mssql-server' | awk '{print \$1}'") -split "`n" |
      Where-Object { $_.Trim() -and $_ -notmatch 'mssql-server-agent' })
})
if ($sqlUnitNames.Count -eq 0) { $sqlUnitNames = @('mssql-server.service') }

foreach ($unitName in $sqlUnitNames) {
    $unitName = $unitName.Trim()
    if ([string]::IsNullOrWhiteSpace($unitName)) { continue }

    # Derive instance name from unit name
    $instanceName = if ($unitName -match '^mssql-server-(.+)\.service$') { $Matches[1] }
                    else { 'MSSQLSERVER' }
    $defaultInstance = ($instanceName -eq 'MSSQLSERVER')
    $endpoint        = if ($defaultInstance) { 'localhost' } else { "localhost\$instanceName" }

    # Service state via systemctl
    $svcState     = (ShellOut "systemctl is-active $unitName 2>/dev/null").Trim()
    $svcEnabled   = (ShellOut "systemctl is-enabled $unitName 2>/dev/null").Trim()
    $serviceState = switch ($svcState) {
        'active'    { 'Running' }
        'inactive'  { 'Stopped' }
        'failed'    { 'Failed'  }
        default     { $svcState }
    }
    $startMode = switch ($svcEnabled) {
        'enabled'   { 'Auto'     }
        'disabled'  { 'Disabled' }
        default     { $svcEnabled }
    }

    # SQL Agent service
    $agentUnit    = if ($defaultInstance) { 'mssql-server-agent.service' }
                    else { "mssql-server-agent-$instanceName.service" }
    $agentState   = (ShellOut "systemctl is-active $agentUnit 2>/dev/null").Trim()
    $sqlAgentState= switch ($agentState) { 'active'{'Running'} 'inactive'{'Stopped'} default{$agentState} }

    # TCP port - read mssql.conf via ShellOut (sudo cat) to avoid PS permission issues
    # when azureuser is not yet in the mssql group or the session hasn't refreshed groups.
    $tcpPort = ''
    try {
        $confFile = if ($defaultInstance) { '/var/opt/mssql/mssql.conf' }
                    else { "/var/opt/mssql/$instanceName/mssql.conf" }
        # Try direct read first; fall back to sudo cat
        $confContent = ShellOut "cat '$confFile' 2>/dev/null || sudo cat '$confFile' 2>/dev/null"
        if ($confContent) {
            $portLine = ($confContent -split "`n") | Where-Object { $_ -match '^\s*tcpport\s*=' } | Select-Object -First 1
            if ($portLine -match '=\s*(\d+)') { $tcpPort = $Matches[1] }
        }
        if (-not $tcpPort) {
            $mcOut = ShellOut "sudo /opt/mssql/bin/mssql-conf get network tcpport 2>/dev/null"
            if ($mcOut -match '(\d{4,5})') { $tcpPort = $Matches[1] }
        }
        if (-not $tcpPort) { $tcpPort = '1433' }
    } catch { $tcpPort = '1433' }

    # SQL data path from mssql.conf (same sudo-fallback pattern)
    $sqlDataPath   = ''
    $sqlLogPath    = ''
    $sqlBackupPath = ''
    try {
        $confFile  = if ($defaultInstance) { '/var/opt/mssql/mssql.conf' } else { "/var/opt/mssql/$instanceName/mssql.conf" }
        $confLines = (ShellOut "cat '$confFile' 2>/dev/null || sudo cat '$confFile' 2>/dev/null") -split "`n"
        $dp = $confLines | Where-Object { $_ -match '^\s*defaultdatadir\s*='  } | Select-Object -First 1
        $lp = $confLines | Where-Object { $_ -match '^\s*defaultlogdir\s*='   } | Select-Object -First 1
        $bp = $confLines | Where-Object { $_ -match '^\s*defaultbackupdir\s*='} | Select-Object -First 1
        if ($dp -match '=\s*(.+)') { $sqlDataPath   = $Matches[1].Trim() }
        if ($lp -match '=\s*(.+)') { $sqlLogPath    = $Matches[1].Trim() }
        if ($bp -match '=\s*(.+)') { $sqlBackupPath = $Matches[1].Trim() }
    } catch {}

    # Engine / database metadata WITHOUT a SQL login: package manager (version), the SQL Server
    # errorlog (edition) and the data directory (file sizes). Not available this way (left empty):
    # licence type/count, product update level, AG/log-shipping/mirroring detail and per-database
    # state, recovery model, compatibility level, owner, creation date, encryption and log reuse wait.
    $engine             = $null
    $sqlConnectionError = $null
    $configuration      = @()
    $databases          = @()
    $databaseFiles      = @()
    $clusterNodes       = @()
    $agReplicas         = @()
    $logShipping        = @()
    $dbMirroring        = @()
    $tcp                = [PSCustomObject]@{ Enabled = 1; Port = $tcpPort; DynamicPorts = '' }

    if (-not $SkipDatabaseDetails -and $serviceState -eq 'Running') {
        try {
            $pkgVersion = ShellOut "rpm -q --qf '%{VERSION}' mssql-server 2>/dev/null || dpkg-query -W -f='`${Version}' mssql-server 2>/dev/null"
            if ($pkgVersion -match 'not installed') { $pkgVersion = '' }
            $pkgVersion = ($pkgVersion -replace '-.*$', '')

            # The errorlog is UTF-16; its first banner line carries the edition.
            $logDir  = if ($defaultInstance) { '/var/opt/mssql/log' } else { "/var/opt/mssql/$instanceName/log" }
            $banner  = ShellOut "(iconv -f UTF-16LE -t UTF-8 '$logDir/errorlog' 2>/dev/null || sudo -n iconv -f UTF-16LE -t UTF-8 '$logDir/errorlog' 2>/dev/null) | grep -m1 'Microsoft SQL Server'"
            $edition = if ($banner -match '(\w+(?: \w+)? Edition(?: \(64-bit\))?)') { $Matches[1] } else { $null }
            $collation = $null
            $spLevel   = if ($banner -match '\((RTM[^)]*|CU\d+[^)]*|GDR[^)]*)\)') { $Matches[1] } else { $null }

            if ($pkgVersion -or $edition) {
                $engine = [PSCustomObject]@{
                    ServerName               = ShellOut 'hostname'
                    MachineName              = ShellOut 'hostname'
                    InstanceName             = if ($defaultInstance) { $null } else { $instanceName }
                    Edition                  = $edition
                    EditionID                = $null
                    ProductVersion           = $pkgVersion
                    ProductLevel             = $spLevel
                    ProductUpdateLevel       = $null
                    ProductUpdateReference   = $null
                    EngineEdition            = $null
                    IsClustered              = 0
                    IsHadrEnabled            = $null
                    IsIntegratedSecurityOnly = $null
                    ServerCollation          = $collation
                    ResourceVersion          = $null
                    LicenseType              = $null
                    NumLicenses              = $null
                    PhysicalNetBIOSName      = ShellOut 'hostname'
                }

                $dataDir = if ($sqlDataPath) { $sqlDataPath } elseif ($defaultInstance) { '/var/opt/mssql/data' } else { "/var/opt/mssql/$instanceName/data" }
                $logDir2 = if ($sqlLogPath) { $sqlLogPath } else { $dataDir }
                $special = @{ mastlog = 'master'; modellog = 'model'; msdbdata = 'msdb'; msdblog = 'msdb'; templog = 'tempdb' }
                $dbSet   = @{}
                foreach ($dir in @($dataDir, $logDir2) | Select-Object -Unique) {
                    $listing = ShellOut "(find '$dir' -maxdepth 1 -type f \( -name '*.mdf' -o -name '*.ndf' -o -name '*.ldf' \) -printf '%s|%p\n' 2>/dev/null || sudo -n find '$dir' -maxdepth 1 -type f \( -name '*.mdf' -o -name '*.ndf' -o -name '*.ldf' \) -printf '%s|%p\n' 2>/dev/null)"
                    foreach ($line in ($listing -split "`n")) {
                        if ($line -notmatch '^(\d+)\|(.+)$') { continue }
                        $bytes = [double]$Matches[1]; $path = $Matches[2]
                        $file  = [System.IO.Path]::GetFileName($path)
                        $base  = [System.IO.Path]::GetFileNameWithoutExtension($file)
                        $isLog = $file.ToLowerInvariant().EndsWith('.ldf')
                        $db    = if ($special.ContainsKey($base.ToLowerInvariant())) { $special[$base.ToLowerInvariant()] }
                                 elseif ($isLog) { $base -replace '_log$', '' } else { $base }
                        $dbSet[$db] = $true
                        $databaseFiles += [PSCustomObject]@{
                            DatabaseName = $db; LogicalFileName = $null; FileType = $(if ($isLog) { 'LOG' } else { 'ROWS' })
                            PhysicalPath = $path; SizeMB = [math]::Round($bytes / 1MB, 2); UsedMB = $null
                            growth = $null; IsPercentGrowth = $null; MaxSizePages = $null
                        }
                    }
                }
                foreach ($dbName in ($dbSet.Keys | Sort-Object)) {
                    $databases += [PSCustomObject]@{
                        database_id = $null; DatabaseName = $dbName; State = $null; UserAccess = $null; RecoveryModel = $null
                        CompatibilityLevel = $null; IsReadOnly = $null; AutoClose = $null; AutoShrink = $null
                        ServiceBrokerEnabled = $null; Trustworthy = $null; DbChaining = $null; Encrypted = $null
                        QueryStoreEnabled = $null; Containment = $null; CreateDate = $null; OwnerName = $null; LogReuseWait = $null
                    }
                }
            } else {
                $sqlConnectionError = 'Package manager and errorlog returned no version or edition for this instance.'
            }
        } catch { $sqlConnectionError = $_.Exception.Message }
    }

    $myHostname = ShellOut 'hostname'
    $agLocalRole = if (@($agReplicas).Count -gt 0) {
        $self = $agReplicas | Where-Object { $_.ReplicaServer -like "$myHostname*" } | Select-Object -First 1
        if ($self) { [string]$self.ReplicaRole } else { $null }
    } else { $null }

    $instances += [PSCustomObject]@{
        ServiceName             = $unitName
        InstanceName            = $instanceName
        IsDefaultInstance       = $defaultInstance
        Endpoint                = $endpoint
        ServiceDisplayName      = "SQL Server ($instanceName)"
        ServiceState            = $serviceState
        ServiceStartMode        = $startMode
        ServiceAccount          = 'mssql'
        SQLAgentState           = $sqlAgentState
        SQLBrowserState         = $null
        InstanceId              = $null
        RegistryEdition         = $null
        RegistryVersion         = $null
        PatchLevel              = $null
        SQLPath                 = $null
        SQLDataRoot             = $sqlDataPath
        DefaultDataPath         = $sqlDataPath
        DefaultLogPath          = $sqlLogPath
        DefaultBackupPath       = $sqlBackupPath
        ServerName              = if ($engine) { $engine.ServerName     } else { $null }
        MachineName             = if ($engine) { $engine.MachineName    } else { $null }
        SQLInstanceName         = if ($engine) { $engine.InstanceName   } else { $instanceName }
        Edition                 = if ($engine) { $engine.Edition        } else { $null }
        EditionID               = if ($engine) { $engine.EditionID      } else { $null }
        ProductVersion          = if ($engine) { $engine.ProductVersion } else { $null }
        ProductLevel            = if ($engine) { $engine.ProductLevel   } else { $null }
        ProductUpdateLevel      = if ($engine) { $engine.ProductUpdateLevel     } else { $null }
        ProductUpdateReference  = if ($engine) { $engine.ProductUpdateReference } else { $null }
        EngineEdition           = if ($engine) { $engine.EngineEdition  } else { $null }
        IsClustered             = if ($engine) { $engine.IsClustered    } else { $null }
        IsHadrEnabled           = if ($engine) { $engine.IsHadrEnabled  } else { $null }
        WindowsAuthenticationOnly = if ($engine) { $engine.IsIntegratedSecurityOnly } else { $null }
        ServerCollation         = if ($engine) { $engine.ServerCollation } else { $null }
        ResourceVersion         = if ($engine) { $engine.ResourceVersion } else { $null }
        TCP                     = $tcp
        SQLConnectionOK         = if ($SkipDatabaseDetails) { $null } else { [bool]$engine }
        SQLConnectionError      = $sqlConnectionError
        LicenseType             = if ($engine) { $engine.LicenseType  } else { $null }
        NumLicenses             = if ($engine) { $engine.NumLicenses  } else { $null }
        ClusterName             = $null
        PhysicalNetBIOSName     = $myHostname
        ClusterNodes            = $clusterNodes
        AGReplicas              = $agReplicas
        AGLocalRole             = $agLocalRole
        AGReadableSecondary     = $null
        IsLogShippingSecondary  = (@($logShipping).Count -gt 0)
        LogShippingDatabases    = $logShipping
        IsMirroringMirror       = @($dbMirroring | Where-Object { $_.MirroringRole -eq 'MIRROR' }).Count -gt 0
        MirroringDatabases      = $dbMirroring
        Configuration           = $configuration
        Databases               = $databases
        DatabaseFiles           = $databaseFiles
        HyperThreadRatio        = $null
        ForcePassive            = $null
        MinVCPUs                = $null
        MinRAMGB                = $null
    }
}

# ---------------------------------------------------------------------------
# ORACLE DISCOVERY - Linux (/etc/oratab, $ORACLE_HOME, sqlplus)
# ---------------------------------------------------------------------------

$oracleInstances = @()

# /etc/oratab: lines like  SID:ORACLE_HOME:Y
$oratab = @()
try {
    if (Test-Path '/etc/oratab') {
        $oratab = @(Get-Content '/etc/oratab' -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '^\s*[^#]' -and $_ -match ':' } |
            ForEach-Object {
                $parts = $_ -split ':'
                if ($parts.Count -ge 2 -and $parts[0].Trim() -ne '' -and $parts[0].Trim() -ne '*') {
                    [PSCustomObject]@{
                        OracleSid  = $parts[0].Trim()
                        OracleHome = $parts[1].Trim()
                        AutoStart  = if ($parts.Count -ge 3) { $parts[2].Trim() } else { '' }
                    }
                }
            } | Where-Object { $_ }
        )
    }
} catch {}

foreach ($entry in $oratab) {
    $sid            = $entry.OracleSid
    $oracleHomePath = $entry.OracleHome
    $oracleBase     = SafeRun { (ShellOut "su -s /bin/bash oracle -c 'echo \$ORACLE_BASE' 2>/dev/null").Trim() }
    if (-not $oracleBase) {
        $oracleBase = ($oracleHomePath -replace '/product/.*','')
    }
    $sqlplusExe     = "$oracleHomePath/bin/sqlplus"
    $oracleVersion  = ''

    # Registry equivalent: oraversion file or sqlplus -v
    try {
        $vFile = "$oracleHomePath/inventory/ContentsXML/comps.xml"
        if (Test-Path $vFile) {
            $vContent = Get-Content $vFile -ErrorAction SilentlyContinue | Select-String -Pattern 'VER="([\d\.]+)"' | Select-Object -First 1
            if ($vContent -match 'VER="([\d\.]+)"') { $oracleVersion = $Matches[1] }
        }
    } catch {}
    if (-not $oracleVersion -and (Test-Path $sqlplusExe)) {
        $verOut = SafeRun { ShellOut "$sqlplusExe -v 2>/dev/null | grep Release" }
        if ($verOut -match 'Release\s+([\d\.]+)') { $oracleVersion = $Matches[1] }
    }

    # Listener
    $listenerPort = '1521'
    $listenerName = ''
    try {
        $lsnrOra = "$oracleHomePath/network/admin/listener.ora"
        if (Test-Path $lsnrOra) {
            $lsnrContent = Get-Content $lsnrOra -ErrorAction SilentlyContinue
            $portLine = $lsnrContent | Where-Object { $_ -match 'PORT\s*=\s*(\d+)' } | Select-Object -First 1
            if ($portLine -match 'PORT\s*=\s*(\d+)') { $listenerPort = $Matches[1] }
            $nameLine = $lsnrContent | Where-Object { $_ -match '^\s*([A-Z_]+)\s*=' } | Select-Object -First 1
            if ($nameLine -match '^\s*([A-Z_]+)\s*=') { $listenerName = $Matches[1] }
        }
    } catch {}

    # Listener service status (systemd)
    $lsnrSvcName  = "oracle-$($listenerName.ToLower())"
    $lsnrState    = (ShellOut "systemctl is-active $lsnrSvcName 2>/dev/null").Trim()
    if (-not $lsnrState -or $lsnrState -eq 'unknown') {
        # Oracle DBs may also run listener via lsnrctl directly, not systemd
        $lsnrPid = (ShellOut "pgrep -f 'tnslsnr' 2>/dev/null").Trim()
        $lsnrState = if ($lsnrPid) { 'Running' } else { 'Stopped' }
    } else {
        $lsnrState = switch ($lsnrState) { 'active'{'Running'} 'inactive'{'Stopped'} default{$lsnrState} }
    }

    # DB service status (oracleXXXXX.service or via pmon process)
    $svcState = 'Unknown'
    try {
        $pmonPid = (ShellOut "pgrep -f 'ora_pmon_$sid' 2>/dev/null").Trim()
        $svcState = if ($pmonPid) { 'Running' } else { 'Stopped' }
    } catch {}

    # Oracle SQL*Plus queries (identical to Windows queries, same output format)
    $oraEdition      = ''
    $oraVersionBanner= ''
    $oraVersionFull  = ''
    $oraHostName     = ''
    $oraInstanceName = ''
    $oraStatus       = ''
    $oraLicense      = ''
    $oraDbRows       = @()
    $oraConnOK       = $false
    $oraDbError      = $null

    if ($svcState -eq 'Running' -or $svcState -eq 'Unknown') {
        try {
            $env_ORACLE_HOME = $oracleHomePath
            $env_ORACLE_SID  = $sid
            $env_PATH        = "$oracleHomePath/bin:$env:PATH"

            if (Test-Path $sqlplusExe) {
                $verQuery = @"
SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SET LINESIZE 512
SELECT NVL(v.banner,'') ||'|'|| NVL(i.version,'') ||'|'|| NVL(i.edition,'') ||'|'|| NVL(i.host_name,'') ||'|'|| NVL(i.instance_name,'') ||'|'|| NVL(i.status,'')
FROM v`$instance i, (SELECT banner FROM v`$version WHERE banner LIKE 'Oracle Database%' AND ROWNUM=1) v;
EXIT;
"@
                $tmpVer = "/tmp/oraverq_$sid.sql"
                [System.IO.File]::WriteAllText($tmpVer, $verQuery)
                $verOut = SafeRun {
                    ShellOut "ORACLE_HOME='$env_ORACLE_HOME' ORACLE_SID='$env_ORACLE_SID' PATH='$env_PATH' su -s /bin/bash oracle -c '$sqlplusExe -S / as sysdba @$tmpVer' 2>/dev/null"
                }
                Remove-Item $tmpVer -ErrorAction SilentlyContinue
                foreach ($line in ($verOut -split "`n")) {
                    if ($line -match '\|') {
                        $cols = $line -split '\|'
                        if ($cols.Count -ge 6) {
                            $oraVersionBanner = $cols[0].Trim()
                            $oraVersionFull   = $cols[1].Trim()
                            $oraEdition       = $cols[2].Trim()
                            $oraHostName      = $cols[3].Trim()
                            $oraInstanceName  = $cols[4].Trim()
                            $oraStatus        = $cols[5].Trim()
                            break
                        }
                    }
                }
                if (-not $oraEdition -and $oraVersionBanner) {
                    if     ($oraVersionBanner -match 'Enterprise') { $oraEdition = 'Enterprise Edition' }
                    elseif ($oraVersionBanner -match 'Standard.*2')  { $oraEdition = 'Standard Edition 2' }
                    elseif ($oraVersionBanner -match 'Standard')  { $oraEdition = 'Standard Edition' }
                    elseif ($oraVersionBanner -match 'Express')   { $oraEdition = 'Express Edition (XE)' }
                    elseif ($oraVersionBanner -match 'Personal')  { $oraEdition = 'Personal Edition' }
                    else                                           { $oraEdition = 'Unknown' }
                }
                $oraLicense = switch -Wildcard ($oraEdition) {
                    '*Enterprise*' { 'Named User Plus or Processor' }
                    '*Standard 2*' { 'Named User Plus or Processor (max 2 sockets)' }
                    '*Standard*'   { 'Named User Plus or Processor' }
                    '*Express*'    { 'Free (XE)' }
                    '*Personal*'   { 'Personal (single user)' }
                    default        { '' }
                }
                if (-not $oracleVersion -and $oraVersionFull) { $oracleVersion = $oraVersionFull }
                if ($oraVersionBanner -or $oraEdition -or $oraVersionFull) { $oraConnOK = $true }

                # Query 2: v$database
                $dbQuery = @"
SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SET LINESIZE 512
SELECT d.name||'|'||d.db_unique_name||'|'||d.open_mode||'|'||d.log_mode||'|'||d.cdb||'|'||NVL(TO_CHAR(d.created,'YYYY-MM-DD HH24:MI:SS'),'')||'|'||d.platform_name||'|'||d.db_version||'|'||NVL(p.pdb_name,'')||'|'||NVL(p.open_mode,'')
FROM v`$database d LEFT JOIN (SELECT pdb_name,open_mode FROM v`$pdbs WHERE pdb_name<>'PDB`$SEED') p ON 1=1;
EXIT;
"@
                $tmpDb = "/tmp/oradbq_$sid.sql"
                [System.IO.File]::WriteAllText($tmpDb, $dbQuery)
                $dbOut = SafeRun {
                    ShellOut "ORACLE_HOME='$env_ORACLE_HOME' ORACLE_SID='$env_ORACLE_SID' PATH='$env_PATH' su -s /bin/bash oracle -c '$sqlplusExe -S / as sysdba @$tmpDb' 2>/dev/null"
                }
                Remove-Item $tmpDb -ErrorAction SilentlyContinue
                foreach ($line in ($dbOut -split "`n")) {
                    if ($line -match '\|') {
                        $cols = $line -split '\|'
                        if ($cols.Count -ge 8) {
                            $oraDbRows += [PSCustomObject]@{
                                DBName       = $cols[0].Trim()
                                DBUniqueName = $cols[1].Trim()
                                OpenMode     = $cols[2].Trim()
                                LogMode      = $cols[3].Trim()
                                IsCDB        = $cols[4].Trim()
                                CreatedDate  = $cols[5].Trim()
                                Platform     = $cols[6].Trim()
                                DBVersion    = $cols[7].Trim()
                                PDBName      = if ($cols.Count -gt 8) { $cols[8].Trim() } else { '' }
                                PDBOpenMode  = if ($cols.Count -gt 9) { $cols[9].Trim() } else { '' }
                            }
                        }
                    }
                }
                $oraConnOK = $true
            }
        } catch { $oraDbError = $_.Exception.Message }
    }

    # Datafile sizes
    $oraDatafiles   = @()
    $_mSize         = $oraDatafiles | ForEach-Object { [double]$_.SizeGB } | Measure-Object -Sum
    $totalDataSizeGB= [double]$(if ($null -ne $_mSize.Sum) { $_mSize.Sum } else { 0 })

    $oracleInstances += [PSCustomObject]@{
        SID              = $sid
        ServiceName      = "oracle-$($sid.ToLower())"
        ServiceState     = $svcState
        ServiceStartMode = $entry.AutoStart
        OracleHome       = $oracleHomePath
        OracleBase       = $oracleBase
        Version          = $oracleVersion
        VersionBanner    = $oraVersionBanner
        Edition          = $oraEdition
        License          = $oraLicense
        ProductLevel     = $oraStatus
        InstanceName     = if ($oraConnOK) { $oraInstanceName } else { $sid }
        HostName         = if ($oraConnOK) { $oraHostName     } else { '' }
        ListenerPort     = $listenerPort
        ListenerName     = $listenerName
        ListenerState    = $lsnrState
        ConnectString    = "localhost:$listenerPort/$sid"
        OracleConnOK     = $oraConnOK
        OracleConnError  = $oraDbError
        Databases        = $oraDbRows
        Datafiles        = $oraDatafiles
        TotalDataSizeGB  = [math]::Round($totalDataSizeGB, 2)
        DatabaseCount    = [int]@($oraDbRows).Count
    }
}

# ---------------------------------------------------------------------------
# RETURN - identical shape to Windows collector
# ---------------------------------------------------------------------------

[PSCustomObject]@{
    VM = [PSCustomObject]@{
        ComputerName          = $hostname
        OS                    = $osCaption
        OSVersion             = $osVersion
        OSBuild               = $osBuild
        OSArchitecture        = $osArch
        TotalPhysicalMemoryGB = $memTotalGB
        LogicalProcessorCount = $logicalCount
        PhysicalCoreCount     = $physCoreCount
        NumberOfProcessors    = $socketCount
        ProcessorName         = $cpuModel
        ProcessorSpeedMHz     = $cpuMHz
        HyperThreadRatio      = $hyperThread
        BIOSVersion           = $null
        Manufacturer          = $null
        Model                 = $null
    }
    Disks   = $disks
    Network = $network
    SQLWMI  = [PSCustomObject]@{ NamespacesFound = @(); Services = @() }
    SQLInstances    = $instances
    OracleInstances = $oracleInstances
}
'@

$RemoteCollector      = [scriptblock]::Create($RemoteCollectorSource)
$LinuxRemoteCollector = [scriptblock]::Create($LinuxCollectorSource)

# ---------------------------------------------------------------------------
# EXECUTE COLLECTION
# ---------------------------------------------------------------------------

$results = @()

# Tracks consecutive WinRM auth failures against the global credential.
# Reset to 0 on any success or when a per-server credential is in use.
$consecutiveAuthFailures = 0

foreach ($server in $servers) {

    # -- Auth-failure lockout guard --------------------------------------------
    # If the global credential has failed $MaxFailedAuthAttempts times in a row,
    # skip remaining targets rather than hammering them and locking the account.
    $usingGlobalCred = (-not $server.IsLinuxOS) -and
                       ($null -eq $server.Credential) -and
                       ($server.Address -notin @('localhost', '127.0.0.1', '::1'))
    if ($MaxFailedAuthAttempts -gt 0 -and
        $usingGlobalCred -and
        $consecutiveAuthFailures -ge $MaxFailedAuthAttempts) {
        $skipMsg = "Skipping $($server.Name) - $consecutiveAuthFailures consecutive auth failures detected. " +
                   "Check the credential or unlock the account before re-running. " +
                   "Use -MaxFailedAuthAttempts 0 to disable this guard."
        Write-Log $skipMsg 'WARN'
        $results += [PSCustomObject]@{
            InputName    = $server.Name
            InputAddress = $server.Address
            Success      = $false
            Error        = $skipMsg
            Data         = $null
            DisplayName  = $server.Name
        }
        continue
    }

    Write-Log "Starting collection [$($server.OS)]: $($server.Name) [$($server.Address)]"

    try {
        $argList = @(
            $(if ($SkipDatabaseDetails) { '1' } else { '0' }),
            $(if ($SkipNetworkDetails)  { '1' } else { '0' })
        )

        if ($server.IsLinuxOS) {
            # -- Linux: SSH transport (requires PowerShell 7+ on both sides) --
            $sshParams = @{
                HostName    = $server.Address
                UserName    = $server.WmiUsername
                ScriptBlock = $LinuxRemoteCollector
                ArgumentList= $argList
                ErrorAction = 'Stop'
            }
            if (-not [string]::IsNullOrWhiteSpace($server.SSHKeyFile) -and (Test-Path $server.SSHKeyFile)) {
                $sshParams['KeyFilePath'] = $server.SSHKeyFile
            }
            $data = Invoke-Command @sshParams
        } else {
            # -- Windows: WinRM transport --------------------------------------
            # For localhost, Invoke-Command -ComputerName localhost routes through
            # the WinRM network stack and hits UAC token filtering -> Access Denied.
            # Run the collector in-process for loopback addresses to avoid this.
            $isLocalhost = $server.Address -in @('localhost', '127.0.0.1', '::1')

            if ($isLocalhost) {
                $data = Invoke-Command `
                    -ScriptBlock  $RemoteCollector `
                    -ArgumentList $argList `
                    -ErrorAction  Stop
            } else {
                $sessionOption       = New-PSSessionOption -OperationTimeout ($OperationTimeoutSec * 1000)
                $effectiveCredential = if ($server.Credential) { $server.Credential } else { $Credential }

                # Debug: log the exact username being used so credential mismatches are visible in the log
                if ($effectiveCredential) {
                    Write-Log "Connecting to $($server.Address) as '$($effectiveCredential.UserName)'"
                }

                if ($effectiveCredential) {
                    $data = Invoke-Command `
                        -ComputerName   $server.Address `
                        -Credential     $effectiveCredential `
                        -Authentication Negotiate `
                        -ScriptBlock    $RemoteCollector `
                        -ArgumentList   $argList `
                        -SessionOption  $sessionOption `
                        -ErrorAction    Stop
                } else {
                    $data = Invoke-Command `
                        -ComputerName   $server.Address `
                        -Authentication Negotiate `
                        -ScriptBlock    $RemoteCollector `
                        -ArgumentList   $argList `
                        -SessionOption  $sessionOption `
                        -ErrorAction    Stop
                }
            }
        }

        $results += [PSCustomObject]@{
            InputName    = $server.Name
            InputAddress = $server.Address
            Success      = $true
            Error        = $null
            Data         = $data
            # Attach the display name to the data object so HTML tables
            # can show the friendly name from config, not the truncated
            # $env:COMPUTERNAME returned by the remote session.
            DisplayName  = $server.Name
        }

        Write-Log "Collection succeeded: $($server.Name)"

        # Reset the consecutive-failure counter on any success.
        if ($usingGlobalCred) { $consecutiveAuthFailures = 0 }

        # -- Remote session cleanup --------------------------------------------
        # Log off any disconnected/idle interactive sessions left on the target
        # by this WinRM connection.  Stale sessions accumulate across runs and
        # eventually trip the account lockout threshold or block new RDP logins.
        # We use `query session` (qwinsta) + `logoff` - both available on every
        # Windows Server SKU.  Errors here are non-fatal: warn and continue.
        if (-not $server.IsLinuxOS -and
            $server.Address -notin @('localhost', '127.0.0.1', '::1')) {
            try {
                $sessionOption2      = New-PSSessionOption -OperationTimeout ($OperationTimeoutSec * 1000)
                $effectiveCred2      = if ($server.Credential) { $server.Credential } else { $Credential }
                $logoffParams        = @{
                    ComputerName   = $server.Address
                    Authentication = 'Negotiate'
                    ScriptBlock    = {
                        # Find all Disc(onnected) sessions belonging to the current WinRM user.
                        # qwinsta output is fixed-width; session IDs are in column 3 (0-based).
                        $lines = @(& qwinsta 2>$null)
                        foreach ($line in $lines) {
                            # Match lines like: " turbowmi          Disc     0  Disc"
                            if ($line -match '^\s+(\S+)\s+\S*\s+(\d+)\s+Disc') {
                                $sessionId = $Matches[2]
                                & logoff $sessionId /server:localhost 2>$null | Out-Null
                            }
                        }
                    }
                    SessionOption  = $sessionOption2
                    ErrorAction    = 'Stop'
                }
                if ($effectiveCred2) { $logoffParams['Credential'] = $effectiveCred2 }
                Invoke-Command @logoffParams
                Write-Log "Remote session cleanup complete: $($server.Name)"
            } catch {
                Write-Log "Remote session cleanup skipped for $($server.Name): $($_.Exception.Message)" 'WARN'
            }
        }
    }
    catch {
        # Walk the full exception chain to surface root cause
        $ex   = $_.Exception
        $msgs = @()
        while ($ex) {
            if ($ex.Message) { $msgs += $ex.Message }
            $ex = $ex.InnerException
        }
        $message = $msgs -join ' --> '

        Write-Log "Collection failed: $($server.Name) - $message" 'ERROR'

        # Increment the consecutive-failure counter only for global-cred auth errors.
        # "Access is denied" is the canonical WinRM auth-failure message.
        if ($usingGlobalCred -and $message -match 'Access is denied|AuthenticationException|LogonFailure') {
            $consecutiveAuthFailures++
            Write-Log ("Auth failure $consecutiveAuthFailures/$MaxFailedAuthAttempts " +
                       "against global credential on $($server.Name)") 'WARN'
        } else {
            # Non-auth error (network timeout, WMI error, etc.) - don't count toward lockout guard.
            if ($usingGlobalCred) { $consecutiveAuthFailures = 0 }
        }

        $results += [PSCustomObject]@{
            InputName    = $server.Name
            InputAddress = $server.Address
            Success      = $false
            Error        = $message
            Data         = $null
            DisplayName  = $server.Name
        }
    }
}

# ---------------------------------------------------------------------------
# DERIVE - compute all display fields once, shared by CSV and HTML
# ---------------------------------------------------------------------------
# Each entry: the raw instance PSCustomObject + all derived string fields.
# This eliminates the duplicated derivation logic that previously existed
# separately in the CSV block and the HTML block.

function Get-InstanceDerived {
    param(
        [PSCustomObject]$Result,
        [PSCustomObject]$Instance,
        [PSCustomObject]$CsvServer      # matching row from $servers
    )

    # -- Edition / version with registry fallback -----------------------------
    $edition = if ($Instance.Edition)        { $Instance.Edition        } else { $Instance.RegistryEdition }
    $version = if ($Instance.ProductVersion) { $Instance.ProductVersion } else { $Instance.RegistryVersion  }

    # -- TCP port -------------------------------------------------------------
    $tcpPort = if ($Instance.TCP) { [string]$Instance.TCP.Port } else { '' }

    # -- Licensing label -------------------------------------------------------
    # Map raw LicenseType token to a human-readable label used in the report.
    #   PER_CORE  -> Licensed by Cores
    #   PER_SEAT  -> S/CAL (Server + CAL) or NUP
    #   DISABLED  -> Not Licensed (Dev / Eval / Express)
    #   UNKNOWN   -> Unknown
    $licenseLabel = switch ([string]$Instance.LicenseType) {
        'PER_CORE' { 'Per Core' }
        'PER_SEAT' { 'S/CAL or NUP' }
        'DISABLED' { 'Not Licensed (Dev/Eval/Express)' }
        default    { [string]$Instance.LicenseType }
    }

    # -- Cluster node role -----------------------------------------------------
    # Uses ClusterNodes rows returned from sys.dm_os_cluster_nodes.
    # PhysicalNetBIOSName = this node's NetBIOS name (matches NodeName column).
    $thisNode = $Instance.ClusterNodes |
                    Where-Object { $_.NodeName -eq $Instance.PhysicalNetBIOSName } |
                    Select-Object -First 1
    $clusterNodeRole = if ($Instance.IsClustered -eq 1) {
        if     ($thisNode -and [string]$thisNode.IsCurrentOwner -eq '1') { 'Active (Owner)' }
        elseif ($thisNode) { 'Passive' }
        else               { 'Unknown' }
    } else { '' }

    # -- AG name(s) ------------------------------------------------------------
    $agNames = @($Instance.AGReplicas | ForEach-Object { $_.AGName } | Sort-Object -Unique)

    # -- AG / cluster role -> active or read-replica ---------------------------
    # Priority: AG role (when HADR enabled) > FCI role > Standalone
    $activeOrReadReplica = if ($Instance.AGLocalRole) {
        if ($Instance.AGLocalRole -eq 'PRIMARY') {
            'Active (Primary)'
        } elseif ([string]$Instance.AGReadableSecondary -in @('YES','READ_ONLY_INTENT_ONLY')) {
            'Read-Replica (Readable Secondary)'
        } else {
            'Passive (Non-Readable Secondary)'
        }
    } elseif ($Instance.IsClustered -eq 1) {
        $clusterNodeRole
    } elseif ($Instance.IsHadrEnabled -eq 1) {
        # Always On is enabled but the replica role needs a SQL connection, so it is not known.
        'Always On enabled (role not collected)'
    } else {
        'Standalone'
    }

    # -- Passive via non-cluster mechanism -------------------------------------
    # Detected by querying log_shipping_secondary_databases and database_mirroring.
    $passiveMethods = @()
    if ($Instance.IsLogShippingSecondary) { $passiveMethods += 'Log Shipping' }
    if ($Instance.IsMirroringMirror)      { $passiveMethods += 'DB Mirroring' }

    # -- Hyper-threading ratio -------------------------------------------------
    # LogicalProcessorCount / PhysicalCoreCount - both collected from Win32_Processor via WMI.
    # Typical values: 2.0 = HT enabled, 1.0 = HT disabled or VM with no HT.
    $vm = if ($Result.Data) { $Result.Data.VM } else { $null }
    $hyperThreadRatio = if ($vm -and
                            $vm.PhysicalCoreCount -gt 0 -and
                            $vm.LogicalProcessorCount -gt 0) {
        [math]::Round([double]$vm.LogicalProcessorCount / [double]$vm.PhysicalCoreCount, 2)
    } else { $null }

    # -- Manual/vendor fields from config ------------------------------------
    $forcePassive = if ($CsvServer) { [string]$CsvServer.ForcePassive } else { '' }
    $minVCPUs     = if ($CsvServer) { [string]$CsvServer.MinVCPUs     } else { '' }
    $minRAMGB     = if ($CsvServer) { [string]$CsvServer.MinRAMGB     } else { '' }

    [PSCustomObject]@{
        # -- Traceability -----------------------------------------------------
        VM                      = [string]$Result.DisplayName
        Address                 = [string]$Result.InputAddress
        # Raw instance object - kept so callers can access all original fields
        _Instance               = $Instance

        # -- Core identity -----------------------------------------------------
        InstanceName            = [string]$Instance.InstanceName
        Endpoint                = [string]$Instance.Endpoint
        ServiceState            = [string]$Instance.ServiceState
        ServiceAccount          = [string]$Instance.ServiceAccount
        Edition                 = [string]$edition
        ProductVersion          = [string]$version
        ProductLevel            = [string]$Instance.ProductLevel
        ProductUpdateLevel      = [string]$Instance.ProductUpdateLevel
        EngineEdition           = [string]$Instance.EngineEdition

        # -- Licensing ---------------------------------------------------------
        LicenseType             = [string]$Instance.LicenseType    # raw token
        LicenseLabel            = [string]$licenseLabel             # human-readable
        NumLicenses             = [string]$Instance.NumLicenses

        # -- Cluster -----------------------------------------------------------
        IsClustered             = [string]$Instance.IsClustered
        ClusterName             = [string]$Instance.ClusterName
        ClusterNodeRole         = [string]$clusterNodeRole          # Active (Owner) | Passive | ''

        # -- Always On AG ------------------------------------------------------
        IsHadrEnabled           = [string]$Instance.IsHadrEnabled
        AGNames                 = [string]($agNames -join '; ')
        AGLocalRole             = [string]$Instance.AGLocalRole     # PRIMARY | SECONDARY | RESOLVING

        # -- Active / read-replica summary ------------------------------------
        ActiveOrReadReplica     = [string]$activeOrReadReplica

        # -- Passive (non-cluster) ---------------------------------------------
        PassiveMethod           = [string]($passiveMethods -join '; ')
        IsLogShippingSecondary  = [string]$Instance.IsLogShippingSecondary
        IsMirroringMirror       = [string]$Instance.IsMirroringMirror

        # -- Host topology -----------------------------------------------------
        HyperThreadRatio        = $hyperThreadRatio   # LogicalProcessors / PhysicalCores

        # -- Manual / vendor ---------------------------------------------------
        ForcePassive            = [string]$forcePassive
        MinVCPUs                = [string]$minVCPUs
        MinRAMGB                = [string]$minRAMGB

        # -- Connectivity ------------------------------------------------------
        WindowsAuthenticationOnly = [string]$Instance.WindowsAuthenticationOnly
        SQLConnectionOK         = [string]$Instance.SQLConnectionOK
        SQLConnectionError      = [string]$Instance.SQLConnectionError
        DatabaseCount           = [int]@($Instance.Databases | Where-Object { $_ }).Count
        TCPPort                 = [string]$tcpPort
        SQLAgentState           = [string]$Instance.SQLAgentState
        SQLBrowserState         = [string]$Instance.SQLBrowserState
        SQLPath                 = [string]$Instance.SQLPath
    }
}

$derivedInstances = @(foreach ($result in $results) {
    if (-not ($result.Success -and $result.Data)) { continue }
    $csvServer = $servers | Where-Object { $_.Name -eq $result.DisplayName } | Select-Object -First 1
    foreach ($inst in @($result.Data.SQLInstances)) {
        Get-InstanceDerived -Result $result -Instance $inst -CsvServer $csvServer
    }
})

# ---------------------------------------------------------------------------
# JSON
# ---------------------------------------------------------------------------

$report = [PSCustomObject]@{
    GeneratedAt  = (Get-Date).ToUniversalTime().ToString('o')
    Collector    = [string]$env:COMPUTERNAME
    VMCount      = [int]$servers.Count
    SuccessCount = [int]@($results | Where-Object { $_.Success }).Count
    FailureCount = [int]@($results | Where-Object { -not $_.Success }).Count
    Servers      = $results
}

$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

# ---------------------------------------------------------------------------
# CSV
# ---------------------------------------------------------------------------

$instanceRows = @(foreach ($d in $derivedInstances) {
    [PSCustomObject]@{
        VM                        = $d.VM
        Address                   = $d.Address
        Instance                  = $d.InstanceName
        Endpoint                  = $d.Endpoint
        ServiceState              = $d.ServiceState
        ServiceAccount            = $d.ServiceAccount
        Edition                   = $d.Edition
        ProductVersion            = $d.ProductVersion
        ProductLevel              = $d.ProductLevel
        ProductUpdateLevel        = $d.ProductUpdateLevel
        EngineEdition             = $d.EngineEdition
        LicenseType               = $d.LicenseType
        LicenseLabel              = $d.LicenseLabel
        NumLicenses               = $d.NumLicenses
        IsClustered               = $d.IsClustered
        ClusterName               = $d.ClusterName
        ClusterNodeRole           = $d.ClusterNodeRole
        IsHadrEnabled             = $d.IsHadrEnabled
        AGNames                   = $d.AGNames
        AGLocalRole               = $d.AGLocalRole
        ActiveOrReadReplica       = $d.ActiveOrReadReplica
        PassiveMethod             = $d.PassiveMethod
        IsLogShippingSecondary    = $d.IsLogShippingSecondary
        IsMirroringMirror         = $d.IsMirroringMirror
        HyperThreadRatio          = $d.HyperThreadRatio
        ForcePassive              = $d.ForcePassive
        MinVCPUs                  = $d.MinVCPUs
        MinRAMGB                  = $d.MinRAMGB
        WindowsAuthenticationOnly = $d.WindowsAuthenticationOnly
        SQLConnectionOK           = $d.SQLConnectionOK
        DatabaseCount             = $d.DatabaseCount
        TCPPort                   = $d.TCPPort
        SQLAgentState             = $d.SQLAgentState
        SQLBrowserState           = $d.SQLBrowserState
        SQLPath                   = $d.SQLPath
    }
})

$instanceRows | Export-Csv -LiteralPath $instanceCsvPath -NoTypeInformation -Encoding UTF8

$databaseRows = @(foreach ($result in $results) {
    if (-not ($result.Success -and $result.Data)) { continue }
    foreach ($instance in @($result.Data.SQLInstances)) {
        foreach ($db in @($instance.Databases)) {
            $files  = @($instance.DatabaseFiles | Where-Object { $_.DatabaseName -eq $db.DatabaseName })
            $sizeFiles = @($files | Where-Object { $null -ne $_.SizeMB -and "$($_.SizeMB)" -match '^\d' })
            $usedFiles = @($files | Where-Object { $null -ne $_.UsedMB -and "$($_.UsedMB)" -match '^\d' })
            $sizeMB = if ($sizeFiles.Count -gt 0) { [double]($sizeFiles | Measure-Object -Property SizeMB -Sum).Sum } else { 0.0 }
            # Used space is only meaningful when every file has a value; log-only values would understate it.
            $usedMB = if ($files.Count -gt 0 -and $usedFiles.Count -eq $files.Count) { [double]($usedFiles | Measure-Object -Property UsedMB -Sum).Sum } else { $null }

            [PSCustomObject]@{
                VM               = [string]$result.DisplayName
                Instance         = [string]$instance.InstanceName
                Database         = [string]$db.DatabaseName
                State            = [string]$db.State
                UserAccess       = [string]$db.UserAccess
                RecoveryModel    = [string]$db.RecoveryModel
                CompatibilityLevel = [string]$db.CompatibilityLevel
                SizeGB           = [math]::Round($sizeMB / 1024, 2)
                UsedGB           = if ($null -ne $usedMB) { [math]::Round($usedMB / 1024, 2) } else { '' }
                ReadOnly         = [string]$db.IsReadOnly
                Encrypted        = [string]$db.Encrypted
                QueryStoreEnabled= [string]$db.QueryStoreEnabled
                Owner            = [string]$db.OwnerName
                CreateDate       = [string]$db.CreateDate
                LogReuseWait     = [string]$db.LogReuseWait
            }
        }
    }
})

$databaseRows | Export-Csv -LiteralPath $databaseCsvPath -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------------------
# HTML DASHBOARD
# ---------------------------------------------------------------------------

$totalVMs      = [int]$servers.Count
$successfulVMs = [int]@($results | Where-Object { $_.Success }).Count
$failedVMs     = [int]@($results | Where-Object { -not $_.Success }).Count

# $derivedInstances already built above - reuse directly for HTML.
$allDatabases   = $databaseRows
$totalInstances = $derivedInstances.Count
$totalDatabases = $allDatabases.Count

# Edition/Version groups - must be computed before chart data that references them.
$editionGroups = @(
    $derivedInstances | ForEach-Object {
        if (-not [string]::IsNullOrWhiteSpace($_.Edition)) { $_.Edition }
    } | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending
)
$versionGroups = @(
    $derivedInstances | ForEach-Object {
        if (-not [string]::IsNullOrWhiteSpace($_.ProductVersion)) { $_.ProductVersion }
    } | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending
)

# -- Chart data (JSON arrays embedded into the HTML template) -----------------

# Chart 1 - Edition breakdown (bar chart)
$chartEditionLabels = ($editionGroups | ForEach-Object {
    '"' + ($_.Name -replace '"','\"') + '"'
}) -join ','
$chartEditionCounts = ($editionGroups | ForEach-Object { $_.Count }) -join ','

# Chart 2 - Version breakdown
$chartVersionLabels = ($versionGroups | ForEach-Object {
    '"' + ($_.Name -replace '"','\"') + '"'
}) -join ','
$chartVersionCounts = ($versionGroups | ForEach-Object { $_.Count }) -join ','

# Chart 3 - Memory per VM (GB)
$chartVmLabels = ($results | Where-Object { $_.Success } | ForEach-Object {
    '"' + ($_.DisplayName -replace '"','\"') + '"'
}) -join ','
$chartMemValues = ($results | Where-Object { $_.Success } | ForEach-Object {
    if ($_.Data.VM.TotalPhysicalMemoryGB) { [math]::Round([double]$_.Data.VM.TotalPhysicalMemoryGB, 2) } else { 0 }
}) -join ','

# Chart 4 - Logical CPU per VM
$chartCpuValues = ($results | Where-Object { $_.Success } | ForEach-Object {
    if ($_.Data.VM.LogicalProcessorCount) { [int]$_.Data.VM.LogicalProcessorCount } else { 0 }
}) -join ','

# Chart 5 - Database count per VM
$chartDbValues = ($results | Where-Object { $_.Success } | ForEach-Object {
    [int]@($_.Data.SQLInstances | ForEach-Object { $_.Databases } | Where-Object { $_ }).Count
}) -join ','

# Chart 6 - Disk free vs used % per drive
# Each array is serialised as a proper JSON array so the JS stacked() function
# receives number arrays, not a bare comma-joined string.
$diskChartLabelList = [System.Collections.Generic.List[string]]::new()
$diskChartFreeList  = [System.Collections.Generic.List[double]]::new()
$diskChartUsedList  = [System.Collections.Generic.List[double]]::new()
foreach ($r in $results | Where-Object { $_.Success }) {
    foreach ($d in @($r.Data.Disks)) {
        $diskLabel = ($r.DisplayName + ':' + $d.Drive) -replace '"', '\"'
        $diskChartLabelList.Add($diskLabel)
        $freeVal = [double]$(if ($d.PSObject.Properties.Name -contains 'FreePercent' -and $null -ne $d.FreePercent) { [math]::Round([double]$d.FreePercent, 1) } else { 0.0 })
        $usedVal = [double]$(if ($d.PSObject.Properties.Name -contains 'FreePercent' -and $null -ne $d.FreePercent) { [math]::Round(100.0 - [double]$d.FreePercent, 1) } else { 0.0 })
        $diskChartFreeList.Add($freeVal)
        $diskChartUsedList.Add($usedVal)
    }
}
# Produce valid JSON arrays for embedding directly into JS (e.g. ["vm:C:",...] and [42.1,...])
$chartDiskLabels   = '[' + (($diskChartLabelList | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'
$chartDiskFreeVals = '[' + ($diskChartFreeList -join ',') + ']'
$chartDiskUsedVals = '[' + ($diskChartUsedList -join ',') + ']'

# Chart 7 - HA / Cluster status breakdown (pie)
$standalone  = @($derivedInstances | Where-Object { $_.ActiveOrReadReplica -eq 'Standalone' }).Count
$primary     = @($derivedInstances | Where-Object { $_.ActiveOrReadReplica -like '*Primary*' }).Count
$secondary   = @($derivedInstances | Where-Object { $_.ActiveOrReadReplica -like '*Secondary*' }).Count
$fciActive   = @($derivedInstances | Where-Object { $_.ClusterNodeRole -eq 'Active (Owner)' }).Count
$fciPassive  = @($derivedInstances | Where-Object { $_.ClusterNodeRole -eq 'Passive' }).Count

$instanceHtml = @(foreach ($d in $derivedInstances) {
    "<tr>" +
    "<td>$(HtmlEncode $d.VM)</td>" +
    "<td>$(HtmlEncode $d.InstanceName)</td>" +
    "<td>$(HtmlEncode $d.Endpoint)</td>" +
    "<td>$(HtmlEncode $d.ServiceState)</td>" +
    "<td>$(HtmlEncode $d.Edition)</td>" +
    "<td>$(HtmlEncode $d.ProductVersion)</td>" +
    "<td>$(HtmlEncode $d.ProductLevel)</td>" +
    "<td>$(HtmlEncode $d.LicenseLabel)</td>" +
    "<td>$(HtmlEncode $d.NumLicenses)</td>" +
    "<td>$(HtmlEncode $d.ClusterName)</td>" +
    "<td>$(HtmlEncode $d.ClusterNodeRole)</td>" +
    "<td>$(HtmlEncode $d.AGNames)</td>" +
    "<td>$(HtmlEncode $d.AGLocalRole)</td>" +
    "<td>$(HtmlEncode $d.ActiveOrReadReplica)</td>" +
    "<td>$(HtmlEncode $d.PassiveMethod)</td>" +
    "<td>$(HtmlEncode $d.HyperThreadRatio)</td>" +
    "<td>$(HtmlEncode $d.ForcePassive)</td>" +
    "<td>$(HtmlEncode $d.MinVCPUs)</td>" +
    "<td>$(HtmlEncode $d.MinRAMGB)</td>" +
    "<td>$(HtmlEncode $d.SQLConnectionOK)</td>" +
    "<td>$(HtmlEncode $d.DatabaseCount)</td>" +
    "<td>$(HtmlEncode $d.TCPPort)</td>" +
    "<td>$(HtmlEncode $d.SQLAgentState)</td>" +
    "</tr>"
})

$databaseHtml = @(foreach ($db in $allDatabases) {
    "<tr>" +
    "<td>$(HtmlEncode $db.VM)</td>" +
    "<td>$(HtmlEncode $db.Instance)</td>" +
    "<td>$(HtmlEncode $db.Database)</td>" +
    "<td>$(HtmlEncode $db.State)</td>" +
    "<td>$(HtmlEncode $db.RecoveryModel)</td>" +
    "<td>$(HtmlEncode $db.CompatibilityLevel)</td>" +
    "<td>$(HtmlEncode $db.SizeGB)</td>" +
    "<td>$(HtmlEncode $db.UsedGB)</td>" +
    "<td>$(HtmlEncode $db.ReadOnly)</td>" +
    "<td>$(HtmlEncode $db.Encrypted)</td>" +
    "<td>$(HtmlEncode $db.QueryStoreEnabled)</td>" +
    "<td>$(HtmlEncode $db.Owner)</td>" +
    "<td>$(HtmlEncode $db.CreateDate)</td>" +
    "<td>$(HtmlEncode $db.LogReuseWait)</td>" +
    "</tr>"
})

$vmHtml = @(foreach ($result in $results) {
    if ($result.Success) {
        $vm = $result.Data.VM
        "<tr>" +
        "<td>$(HtmlEncode $result.DisplayName)</td>" +
        "<td>$(HtmlEncode $result.InputAddress)</td>" +
        "<td><span class='ok'>OK</span></td>" +
        "<td>$(HtmlEncode $vm.OS)</td>" +
        "<td>$(HtmlEncode $vm.OSVersion)</td>" +
        "<td>$(HtmlEncode $vm.OSBuild)</td>" +
        "<td>$(HtmlEncode $vm.TotalPhysicalMemoryGB)</td>" +
        "<td>$(HtmlEncode $vm.LogicalProcessorCount)</td>" +
        "<td>$(HtmlEncode $vm.PhysicalCoreCount)</td>" +
        "<td>$(if ($vm.PhysicalCoreCount -gt 0 -and $vm.LogicalProcessorCount -gt 0) { [math]::Round([double]$vm.LogicalProcessorCount / [double]$vm.PhysicalCoreCount, 2) } else { '' })</td>" +
        "<td>$(HtmlEncode $vm.NumberOfProcessors)</td>" +
        "<td>$(@($result.Data.SQLInstances).Count)</td>" +
        "</tr>"
    } else {
        "<tr>" +
        "<td>$(HtmlEncode $result.InputName)</td>" +
        "<td>$(HtmlEncode $result.InputAddress)</td>" +
        "<td><span class='bad'>FAILED</span></td>" +
        "<td colspan='9'>$(HtmlEncode $result.Error)</td>" +
        "</tr>"
    }
})

$diskHtml = @(foreach ($result in $results) {
    if ($result.Success) {
        foreach ($disk in @($result.Data.Disks)) {
            "<tr>" +
            "<td>$(HtmlEncode $result.DisplayName)</td>" +
            "<td>$(HtmlEncode $disk.Drive)</td>" +
            "<td>$(HtmlEncode $disk.VolumeName)</td>" +
            "<td>$(HtmlEncode $disk.FileSystem)</td>" +
            "<td>$(HtmlEncode $disk.SizeGB)</td>" +
            "<td>$(HtmlEncode $disk.FreeGB)</td>" +
            "<td>$(HtmlEncode $disk.FreePercent)</td>" +
            "</tr>"
        }
    }
})

$editionHtml = @($editionGroups | ForEach-Object {
    "<tr><td>$(HtmlEncode $_.Name)</td><td>$($_.Count)</td></tr>"
})
$versionHtml = @($versionGroups | ForEach-Object {
    "<tr><td>$(HtmlEncode $_.Name)</td><td>$($_.Count)</td></tr>"
})
$errorHtml = @($results | Where-Object { -not $_.Success } | ForEach-Object {
    "<tr>" +
    "<td>$(HtmlEncode $_.InputName)</td>" +
    "<td>$(HtmlEncode $_.InputAddress)</td>" +
    "<td>$(HtmlEncode $_.Error)</td>" +
    "</tr>"
})

# Oracle instance rows
$oracleInstHtml = @(foreach ($result in $results) {
    if (-not ($result.Success -and $result.Data)) { continue }
    foreach ($oi in @($result.Data.OracleInstances)) {
        if (-not $oi) { continue }
        $connBadge  = if ($oi.OracleConnOK) { "badge-ok'>Connected" } else { "badge-muted'>Not Connected" }
        $stateBadge = if ([string]$oi.ServiceState -eq 'Running') { "badge-ok'>Running" } else { "badge-warn'>$(HtmlEncode $oi.ServiceState)" }
        "<tr>" +
        "<td>$(HtmlEncode $result.DisplayName)</td>" +
        "<td>$(HtmlEncode $oi.SID)</td>" +
        "<td>$(HtmlEncode $oi.Edition)</td>" +
        "<td>$(HtmlEncode $oi.Version)</td>" +
        "<td>$(HtmlEncode $oi.ProductLevel)</td>" +
        "<td>$(HtmlEncode $oi.License)</td>" +
        "<td><span class='badge $stateBadge</span></td>" +
        "<td>$(HtmlEncode $oi.ServiceName)</td>" +
        "<td>$(HtmlEncode $oi.ServiceStartMode)</td>" +
        "<td>$(HtmlEncode $oi.ListenerPort)</td>" +
        "<td>$(HtmlEncode $oi.ListenerName)</td>" +
        "<td>$(HtmlEncode $oi.ListenerState)</td>" +
        "<td>$(HtmlEncode $oi.ConnectString)</td>" +
        "<td><span class='badge $connBadge</span></td>" +
        "<td>$(HtmlEncode $oi.DatabaseCount)</td>" +
        "<td>$(HtmlEncode $oi.TotalDataSizeGB)</td>" +
        "<td>$(HtmlEncode $oi.OracleHome)</td>" +
        "<td>$(HtmlEncode $oi.OracleBase)</td>" +
        "</tr>"
    }
}) -join "`n"

# Oracle database rows
$oracleDbHtml = @(foreach ($result in $results) {
    if (-not ($result.Success -and $result.Data)) { continue }
    foreach ($oi in @($result.Data.OracleInstances)) {
        if (-not $oi) { continue }
        foreach ($db in @($oi.Databases)) {
            if (-not $db) { continue }
            $cdbBadge = if ($db.IsCDB -eq 'YES') { "badge-info'>CDB" } else { "badge-muted'>Non-CDB" }
            "<tr>" +
            "<td>$(HtmlEncode $result.DisplayName)</td>" +
            "<td>$(HtmlEncode $oi.SID)</td>" +
            "<td>$(HtmlEncode $db.DBName)</td>" +
            "<td>$(HtmlEncode $db.DBUniqueName)</td>" +
            "<td>$(HtmlEncode $db.OpenMode)</td>" +
            "<td>$(HtmlEncode $db.LogMode)</td>" +
            "<td><span class='badge $cdbBadge</span></td>" +
            "<td>$(HtmlEncode $db.PDBName)</td>" +
            "<td>$(HtmlEncode $db.PDBOpenMode)</td>" +
            "<td>$(HtmlEncode $db.DBVersion)</td>" +
            "<td>$(HtmlEncode $db.Platform)</td>" +
            "<td>$(HtmlEncode $db.CreatedDate)</td>" +
            "</tr>"
        }
    }
}) -join "`n"

# Oracle KPI
$totalOracleInstances = [int]@($results | Where-Object { $_.Success -and $_.Data } | ForEach-Object { @($_.Data.OracleInstances) } | Where-Object { $_ }).Count

if (-not $instanceHtml)    { $instanceHtml    = @("<tr><td colspan='23'>No SQL instances discovered.</td></tr>") }
if (-not $databaseHtml)    { $databaseHtml    = @("<tr><td colspan='14'>No database information collected.</td></tr>") }
if (-not $vmHtml)          { $vmHtml          = @("<tr><td colspan='11'>No VM information collected.</td></tr>") }
if (-not $diskHtml)        { $diskHtml        = @("<tr><td colspan='7'>No disk information collected.</td></tr>") }
if (-not $editionHtml)     { $editionHtml     = @("<tr><td colspan='2'>No data</td></tr>") }
if (-not $versionHtml)     { $versionHtml     = @("<tr><td colspan='2'>No data</td></tr>") }
if (-not $errorHtml)       { $errorHtml       = @("<tr><td colspan='3'>No collection errors.</td></tr>") }
if (-not $oracleInstHtml)  { $oracleInstHtml  = "<tr><td colspan='19' style='text-align:center;color:#6b7280;font-style:italic;padding:16px'>No Oracle instances detected on any VM.</td></tr>" }
if (-not $oracleDbHtml)    { $oracleDbHtml    = "<tr><td colspan='12' style='text-align:center;color:#6b7280;font-style:italic;padding:16px'>No Oracle databases collected.</td></tr>" }

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>SQL Server Fleet Inventory</title>
<style>
:root{--bg:#f0f2f5;--surface:#ffffff;--border:#e2e6ea;--text:#1a1d23;--muted:#6b7280;--accent:#0f62fe;--accent-light:#eef3ff;--ok:#198038;--warn:#f1620a;--bad:#da1e28;--nav-w:220px;--hdr:60px}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:-apple-system,"Segoe UI",system-ui,sans-serif;font-size:13px;line-height:1.5}
/* --- Top bar --- */
.topbar{position:fixed;top:0;left:0;right:0;height:var(--hdr);background:#161b22;color:#fff;display:flex;align-items:center;padding:0 24px;gap:16px;z-index:200;box-shadow:0 2px 8px rgba(0,0,0,.35)}
.topbar h1{font-size:17px;font-weight:700;letter-spacing:-.3px;white-space:nowrap}
.topbar .meta{font-size:11px;color:#8b949e;margin-left:auto;white-space:nowrap}
/* --- Sidebar --- */
.sidebar{position:fixed;top:var(--hdr);left:0;width:var(--nav-w);bottom:0;background:#ffffff;border-right:1px solid var(--border);overflow-y:auto;z-index:100;padding:16px 0}
.nav-group{padding:6px 16px 2px;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}
.nav-item{display:block;padding:7px 20px;color:#374151;text-decoration:none;font-size:12.5px;border-left:3px solid transparent;transition:all .15s}
.nav-item:hover,.nav-item.active{background:var(--accent-light);border-left-color:var(--accent);color:var(--accent)}
/* --- Main content --- */
.main{margin-left:var(--nav-w);margin-top:var(--hdr);padding:24px 28px;min-height:calc(100vh - var(--hdr))}
/* --- KPI cards --- */
.kpi-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:14px;margin-bottom:24px}
.kpi{background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:18px 20px;position:relative}
.kpi-val{font-size:30px;font-weight:800;line-height:1}
.kpi-label{font-size:11.5px;color:var(--muted);margin-top:5px}
.kpi.ok .kpi-val{color:var(--ok)}
.kpi.bad .kpi-val{color:var(--bad)}
.kpi.accent .kpi-val{color:var(--accent)}
/* --- Section cards --- */
.section{background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:20px 22px;margin-bottom:22px;scroll-margin-top:calc(var(--hdr) + 16px)}
.section-hdr{display:flex;align-items:center;justify-content:space-between;margin-bottom:14px}
.section-hdr h2{font-size:14px;font-weight:700;display:flex;align-items:center;gap:8px}
.section-hdr h2 .ico{width:20px;height:20px;border-radius:5px;background:var(--accent);display:flex;align-items:center;justify-content:center;color:#fff;font-size:10px;font-weight:800;flex-shrink:0}
/* --- Search --- */
.search-bar{display:flex;gap:8px;margin-bottom:10px}
.search-bar input{flex:1;max-width:360px;padding:7px 11px;border:1px solid var(--border);border-radius:6px;font-size:12px;outline:none}
.search-bar input:focus{border-color:var(--accent);box-shadow:0 0 0 2px rgba(15,98,254,.15)}
/* --- Tables --- */
.tablewrap{overflow-x:auto;border-radius:6px;border:1px solid var(--border)}
table{border-collapse:collapse;width:100%;font-size:12.5px}
thead th{background:#f8f9fb;text-align:left;padding:9px 12px;border-bottom:2px solid var(--border);white-space:nowrap;font-weight:600;color:#374151;font-size:11.5px;position:sticky;top:0}
tbody td{padding:8px 12px;border-bottom:1px solid #f0f2f5;vertical-align:middle}
tbody tr:last-child td{border-bottom:none}
tbody tr:hover td{background:#f8faff}
/* --- Badges --- */
.badge{display:inline-flex;align-items:center;padding:2px 9px;border-radius:20px;font-size:11px;font-weight:600;white-space:nowrap}
.badge-ok{background:#dcf5e6;color:#0a6640}
.badge-warn{background:#fff3cd;color:#856404}
.badge-bad{background:#fde8e8;color:#9b1c1c}
.badge-info{background:#dbeafe;color:#1e40af}
.badge-muted{background:#f3f4f6;color:#4b5563}
/* --- Progress bars --- */
.pbar-wrap{display:flex;align-items:center;gap:7px}
.pbar-track{background:#e5e7eb;border-radius:4px;height:8px;width:100px;flex-shrink:0;overflow:hidden}
.pbar-fill{height:8px;border-radius:4px}
.pbar-label{font-size:11px;color:var(--muted);min-width:34px}
/* --- Chart containers --- */
.charts-row{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:18px;margin-bottom:22px}
.chart-card{background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:18px}
.chart-card h3{font-size:12.5px;font-weight:700;color:var(--muted);margin-bottom:12px;text-transform:uppercase;letter-spacing:.06em}
.chart-card canvas{display:block;max-height:220px}
/* --- Footer --- */
footer{text-align:center;font-size:11px;color:var(--muted);padding:20px;border-top:1px solid var(--border);margin-top:8px}
/* --- Responsive --- */
@media(max-width:800px){.sidebar{display:none}.main{margin-left:0}}
</style>
</head>
<body>

<div class="topbar">
  <h1>&#128202; SQL Server Fleet Inventory</h1>
  <span class="meta">Generated: $(HtmlEncode $report.GeneratedAt) &nbsp;|&nbsp; Collector: $(HtmlEncode $report.Collector)</span>
</div>

<nav class="sidebar">
  <div class="nav-group">Overview</div>
  <a class="nav-item active" href="#summary">&#9711; Summary &amp; Charts</a>
  <div class="nav-group">Host</div>
  <a class="nav-item" href="#vms">&#128187; VM Inventory</a>
  <a class="nav-item" href="#disks">&#128190; Disk Inventory</a>
  <div class="nav-group">SQL Server</div>
  <a class="nav-item" href="#instances">&#9671; SQL Instances</a>
  <a class="nav-item" href="#databases">&#128451; Databases</a>
  <div class="nav-group">Oracle</div>
  <a class="nav-item" href="#oracle-inst">&#9678; Oracle Instances</a>
  <a class="nav-item" href="#oracle-db">&#128448; Oracle Databases</a>
  <div class="nav-group">Reference</div>
  <a class="nav-item" href="#errors">&#9888; Collection Errors</a>
  <a class="nav-item" href="#meta">&#128203; Metadata</a>
</nav>

<main class="main">

<!-- === KPI CARDS === -->
<div class="kpi-grid">
  <div class="kpi accent"><div class="kpi-val">$totalVMs</div><div class="kpi-label">VMs Scanned</div></div>
  <div class="kpi ok"><div class="kpi-val">$successfulVMs</div><div class="kpi-label">Collected OK</div></div>
  <div class="kpi$(if($failedVMs -gt 0){' bad'}else{''})"><div class="kpi-val">$failedVMs</div><div class="kpi-label">Collection Errors</div></div>
  <div class="kpi"><div class="kpi-val">$totalInstances</div><div class="kpi-label">SQL Instances</div></div>
  <div class="kpi"><div class="kpi-val">$totalDatabases</div><div class="kpi-label">SQL Databases</div></div>
  <div class="kpi" style="border-left:3px solid #f1620a"><div class="kpi-val" style="color:#f1620a">$totalOracleInstances</div><div class="kpi-label">Oracle Instances</div></div>
</div>

<!-- === CHARTS === -->
<div id="summary">
<div class="charts-row">

  <div class="chart-card">
    <h3>SQL Edition Distribution</h3>
    <canvas id="cEdition" height="200"></canvas>
  </div>

  <div class="chart-card">
    <h3>SQL Version Distribution</h3>
    <canvas id="cVersion" height="200"></canvas>
  </div>

  <div class="chart-card">
    <h3>HA / Cluster Roles</h3>
    <canvas id="cHA" height="200"></canvas>
  </div>

</div>
<div class="charts-row">

  <div class="chart-card">
    <h3>Memory per VM (GB)</h3>
    <canvas id="cMem" height="200"></canvas>
  </div>

  <div class="chart-card">
    <h3>Logical CPUs per VM</h3>
    <canvas id="cCpu" height="200"></canvas>
  </div>

  <div class="chart-card">
    <h3>Databases per VM</h3>
    <canvas id="cDb" height="200"></canvas>
  </div>

</div>
<div class="charts-row">

  <div class="chart-card" style="grid-column:1/-1">
    <h3>Disk Usage - Free vs Used (%)</h3>
    <canvas id="cDisk" height="160"></canvas>
  </div>

</div>
</div>

<!-- === VM INVENTORY === -->
<div class="section" id="vms">
  <div class="section-hdr"><h2><span class="ico">H</span>VM Inventory</h2></div>
  <div class="tablewrap"><table>
  <thead><tr>
    <th>VM Name</th><th>Address</th><th>Status</th><th>OS</th><th>OS Version</th>
    <th>Build</th><th>Memory (GB)</th><th>Logical CPUs</th><th>Physical Cores</th><th>HT Ratio</th><th>Sockets</th><th>SQL Instances</th>
  </tr></thead>
  <tbody>$($vmHtml -join "`n")</tbody>
  </table></div>
</div>

<!-- === SQL INSTANCES === -->
<div class="section" id="instances">
  <div class="section-hdr">
    <h2><span class="ico">S</span>SQL Server Instances</h2>
  </div>
  <p style="font-size:11.5px;color:#6b7280;margin:0 0 8px">Collected without a SQL connection (WMI, registry, files). Licence type/count, AG / log-shipping / mirroring detail and per-database properties are not available this way and are shown empty.</p>
  <div class="search-bar"><input id="instanceFilter" placeholder="&#128269; Filter instances..." oninput="ft('instanceTable','instanceFilter')"></div>
  <div class="tablewrap"><table id="instanceTable">
  <thead><tr>
    <th>Machine</th><th>Instance</th><th>Endpoint</th><th>Service State</th>
    <th>Edition</th><th>Version</th><th>Product Level</th>
    <th>License</th><th>Num Licenses</th>
    <th>Cluster Name</th><th>Cluster Node Role</th>
    <th>AG Name(s)</th><th>AG Role</th><th>Active / Read-Replica</th>
    <th>Passive Method</th><th>HT Ratio</th><th>Force Passive</th>
    <th>Min vCPUs</th><th>Min RAM (GB)</th>
    <th>Metadata OK</th><th>DB Count</th><th>TCP Port</th><th>Agent</th>
  </tr></thead>
  <tbody>$($instanceHtml -join "`n")</tbody>
  </table></div>
</div>

<!-- === DATABASES === -->
<div class="section" id="databases">
  <div class="section-hdr">
    <h2><span class="ico">D</span>Databases</h2>
  </div>
  <p style="font-size:11.5px;color:#6b7280;margin:0 0 8px">Database names, file sizes and log used space come from WMI counters and data files. State, recovery model, compatibility, owner, creation date, encryption and log reuse wait need a SQL connection and are empty. Used (GB) is shown only when every file reports it.</p>
  <div class="search-bar"><input id="databaseFilter" placeholder="&#128269; Filter databases..." oninput="ft('databaseTable','databaseFilter')"></div>
  <div class="tablewrap"><table id="databaseTable">
  <thead><tr>
    <th>VM</th><th>Instance</th><th>Database</th><th>State</th>
    <th>Recovery</th><th>Compat.</th><th>Size (GB)</th><th>Used (GB)</th>
    <th>Read Only</th><th>Encrypted</th><th>Query Store</th><th>Owner</th>
    <th>Created</th><th>Log Reuse Wait</th>
  </tr></thead>
  <tbody>$($databaseHtml -join "`n")</tbody>
  </table></div>
</div>

<!-- === DISK === -->
<div class="section" id="disks">
  <div class="section-hdr"><h2><span class="ico">&#128190;</span>Disk Inventory</h2></div>
  <div class="tablewrap"><table>
  <thead><tr>
    <th>VM</th><th>Drive</th><th>Volume</th><th>File System</th>
    <th>Size (GB)</th><th>Free (GB)</th><th>Free %</th>
  </tr></thead>
  <tbody>$($diskHtml -join "`n")</tbody>
  </table></div>
</div>

<!-- === ORACLE INSTANCES === -->
<div class="section" id="oracle-inst">
  <div class="section-hdr">
    <h2><span class="ico" style="background:#f1620a">O</span>Oracle Instances</h2>
  </div>
  <div class="search-bar"><input id="oracleInstFilter" placeholder="&#128269; Filter Oracle instances..." oninput="ft('oracleInstTable','oracleInstFilter')"></div>
  <div class="tablewrap"><table id="oracleInstTable">
  <thead><tr>
    <th>VM</th><th>SID</th><th>Edition</th><th>Version</th><th>Product Level</th><th>License</th>
    <th>Service State</th><th>Service Name</th><th>Start Mode</th>
    <th>Listener Port</th><th>Listener Name</th><th>Listener State</th>
    <th>Connect String</th><th>SQL*Plus Connected</th>
    <th>DB Count</th><th>Total Data Size (GB)</th>
    <th>Oracle Home</th><th>Oracle Base</th>
  </tr></thead>
  <tbody>$oracleInstHtml</tbody>
  </table></div>
</div>

<!-- === ORACLE DATABASES === -->
<div class="section" id="oracle-db">
  <div class="section-hdr">
    <h2><span class="ico" style="background:#f1620a">D</span>Oracle Databases / PDBs</h2>
  </div>
  <div class="search-bar"><input id="oracleDbFilter" placeholder="&#128269; Filter Oracle databases..." oninput="ft('oracleDbTable','oracleDbFilter')"></div>
  <div class="tablewrap"><table id="oracleDbTable">
  <thead><tr>
    <th>VM</th><th>SID</th><th>DB Name</th><th>DB Unique Name</th>
    <th>Open Mode</th><th>Log Mode</th><th>CDB Type</th>
    <th>PDB Name</th><th>PDB Open Mode</th>
    <th>DB Version</th><th>Platform</th><th>Created</th>
  </tr></thead>
  <tbody>$oracleDbHtml</tbody>
  </table></div>
</div>

<!-- === ERRORS === -->
<div class="section" id="errors">
  <div class="section-hdr"><h2><span class="ico">!</span>Collection Errors</h2></div>
  <div class="tablewrap"><table>
  <thead><tr><th>VM</th><th>Address</th><th>Error</th></tr></thead>
  <tbody>$($errorHtml -join "`n")</tbody>
  </table></div>
</div>

<!-- === METADATA === -->
<div class="section" id="meta">
  <div class="section-hdr"><h2><span class="ico">i</span>Collection Metadata</h2></div>
  <table style="min-width:0;width:auto">
    <tr><td style="font-weight:600;padding:5px 14px 5px 0;color:var(--muted)">Generated (UTC)</td><td>$(HtmlEncode $report.GeneratedAt)</td></tr>
    <tr><td style="font-weight:600;padding:5px 14px 5px 0;color:var(--muted)">Collector</td><td>$(HtmlEncode $report.Collector)</td></tr>
    <tr><td style="font-weight:600;padding:5px 14px 5px 0;color:var(--muted)">JSON</td><td>$(HtmlEncode $jsonPath)</td></tr>
    <tr><td style="font-weight:600;padding:5px 14px 5px 0;color:var(--muted)">Instances CSV</td><td>$(HtmlEncode $instanceCsvPath)</td></tr>
    <tr><td style="font-weight:600;padding:5px 14px 5px 0;color:var(--muted)">Databases CSV</td><td>$(HtmlEncode $databaseCsvPath)</td></tr>
  </table>
</div>

</main>

<footer>SQL Server Fleet Inventory &nbsp;|&nbsp; Made with IBM Bob</footer>

<script>
/* --- Table filter --- */
function ft(tId,iId){
  var f=document.getElementById(iId).value.toLowerCase();
  var rows=document.getElementById(tId).getElementsByTagName('tr');
  for(var i=1;i<rows.length;i++)
    rows[i].style.display=rows[i].innerText.toLowerCase().indexOf(f)>=0?'':'none';
}

/* --- Active nav highlight on scroll --- */
(function(){
  var items=document.querySelectorAll('.nav-item[href^="#"]');
  var targets=[].map.call(items,function(a){return document.querySelector(a.getAttribute('href'))});
  function upd(){
    var y=window.scrollY+80;
    var cur=-1;
    targets.forEach(function(t,i){if(t&&t.offsetTop<=y)cur=i});
    items.forEach(function(a,i){a.classList.toggle('active',i===cur)});
  }
  window.addEventListener('scroll',upd,{passive:true});upd();
})();

/* --- Minimal SVG chart engine (no external deps) --- */
(function(){
  var COLORS=['#0f62fe','#198038','#f1620a','#8b5cf6','#da1e28','#06b6d4','#f59e0b','#10b981'];

  function el(tag,attrs,parent){
    var e=document.createElementNS('http://www.w3.org/2000/svg',tag);
    for(var k in attrs)e.setAttribute(k,attrs[k]);
    if(parent)parent.appendChild(e);
    return e;
  }
  function mkSvg(canvas,w,h){
    var svg=el('svg',{viewBox:'0 0 '+w+' '+h,width:'100%',height:'100%','font-family':'inherit','font-size':'11'});
    canvas.parentNode.replaceChild(svg,canvas);
    return svg;
  }

  /* Horizontal bar chart */
  function hbar(canvasId,labels,values,color){
    var c=document.getElementById(canvasId);if(!c)return;
    var W=500,barH=26,gap=8,padL=200,padR=40,padT=10,padB=10;
    var n=labels.length;
    var H=padT+n*(barH+gap)-gap+padB;
    var svg=mkSvg(c,W,H);
    var maxV=Math.max.apply(null,values)||1;
    labels.forEach(function(lbl,i){
      var y=padT+i*(barH+gap);
      var bw=Math.max(2,(values[i]/maxV)*(W-padL-padR));
      el('text',{x:padL-6,y:y+barH/2+4,'text-anchor':'end',fill:'#374151'},svg).textContent=lbl;
      el('rect',{x:padL,y:y,width:W-padL-padR,height:barH,rx:4,fill:'#f0f2f5'},svg);
      el('rect',{x:padL,y:y,width:bw,height:barH,rx:4,fill:color||COLORS[0]},svg);
      el('text',{x:padL+bw+5,y:y+barH/2+4,fill:'#374151'},svg).textContent=values[i];
    });
  }

  /* Pie / donut chart */
  function pie(canvasId,labels,values){
    var c=document.getElementById(canvasId);if(!c)return;
    var W=420,H=200,cx=100,cy=100,r=85,ir=50;
    var svg=mkSvg(c,W,H);
    var total=values.reduce(function(a,b){return a+b},0)||1;
    var angle=-Math.PI/2;
    values.forEach(function(v,i){
      if(v===0)return;
      var sweep=2*Math.PI*(v/total);
      var x1=cx+r*Math.cos(angle),y1=cy+r*Math.sin(angle);
      var x2=cx+r*Math.cos(angle+sweep),y2=cy+r*Math.sin(angle+sweep);
      var xi1=cx+ir*Math.cos(angle),yi1=cy+ir*Math.sin(angle);
      var xi2=cx+ir*Math.cos(angle+sweep),yi2=cy+ir*Math.sin(angle+sweep);
      var lg=sweep>Math.PI?1:0;
      var d='M'+xi1+' '+yi1+' L'+x1+' '+y1+' A'+r+' '+r+' 0 '+lg+' 1 '+x2+' '+y2+' L'+xi2+' '+yi2+' A'+ir+' '+ir+' 0 '+lg+' 0 '+xi1+' '+yi1+'Z';
      el('path',{d:d,fill:COLORS[i%COLORS.length]},svg);
      angle+=sweep;
    });
    /* Legend */
    var ly=16;
    labels.forEach(function(lbl,i){
      if(values[i]===0)return;
      el('rect',{x:210,y:ly-10,width:12,height:12,rx:2,fill:COLORS[i%COLORS.length]},svg);
      el('text',{x:228,y:ly,fill:'#374151'},svg).textContent=lbl+' ('+values[i]+')';
      ly+=20;
    });
  }

  /* Grouped bar (stacked horizontal) */
  function stacked(canvasId,labels,series,seriesLabels){
    var c=document.getElementById(canvasId);if(!c)return;
    var W=700,barH=22,gap=8,padL=200,padR=50,padT=30,padB=10;
    var n=labels.length;
    var H=padT+n*(barH+gap)-gap+padB;
    var maxV=0;
    labels.forEach(function(_,i){
      var s=series.reduce(function(a,arr){return a+arr[i]},0);
      if(s>maxV)maxV=s;
    });
    maxV=maxV||1;
    var svg=mkSvg(c,W,H);
    /* legend */
    var lx=padL;
    seriesLabels.forEach(function(lbl,i){
      el('rect',{x:lx,y:8,width:12,height:12,rx:2,fill:COLORS[i%COLORS.length]},svg);
      el('text',{x:lx+16,y:18,fill:'#374151'},svg).textContent=lbl;
      lx+=lbl.length*7+30;
    });
    labels.forEach(function(lbl,i){
      var y=padT+i*(barH+gap);
      el('text',{x:padL-6,y:y+barH/2+4,'text-anchor':'end',fill:'#374151'},svg).textContent=lbl;
      el('rect',{x:padL,y:y,width:W-padL-padR,height:barH,rx:4,fill:'#f0f2f5'},svg);
      var ox=padL;
      series.forEach(function(arr,si){
        var bw=(arr[i]/maxV)*(W-padL-padR);
        if(bw>0)el('rect',{x:ox,y:y,width:bw,height:barH,rx:si===0&&arr[i]>0?4:0,fill:COLORS[si%COLORS.length]},svg);
        ox+=bw;
      });
      var tot=series.reduce(function(a,arr){return a+arr[i]},0);
      el('text',{x:ox+5,y:y+barH/2+4,fill:'#374151'},svg).textContent=tot+'%';
    });
  }

  /* Wire up charts once DOM ready */
  hbar('cEdition',[$chartEditionLabels],[$chartEditionCounts],'#0f62fe');
  hbar('cVersion',[$chartVersionLabels],[$chartVersionCounts],'#8b5cf6');
  pie('cHA',['Standalone','AG Primary','AG Secondary','FCI Active','FCI Passive'],[$standalone,$primary,$secondary,$fciActive,$fciPassive]);
  hbar('cMem',[$chartVmLabels],[$chartMemValues],'#198038');
  hbar('cCpu',[$chartVmLabels],[$chartCpuValues],'#f1620a');
  hbar('cDb',[$chartVmLabels],[$chartDbValues],'#06b6d4');
  stacked('cDisk',$chartDiskLabels,[$chartDiskUsedVals,$chartDiskFreeVals],['Used %','Free %']);
})();
</script>
</body>
</html>
"@

Set-Content -LiteralPath $htmlPath -Value $html -Encoding UTF8

# ---------------------------------------------------------------------------
# CLEANUP - remove TrustedHosts entries added by this run
# ---------------------------------------------------------------------------

if ($addedTrustedHosts.Count -gt 0) {
    try {
        $currentTrusted = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
        # Never modify a wildcard '*' - removing individual entries from '*' would
        # clear all trusted hosts and lock out future WinRM connections.
        if ($currentTrusted -eq '*') {
            Write-Log "TrustedHosts is '*' - skipping cleanup to preserve wildcard"
        } else {
            $remaining = (@($currentTrusted -split ',' |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -ne '' -and $addedTrustedHosts -notcontains $_ }) -join ',')
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value $remaining -Force -ErrorAction Stop
            Write-Log "Removed temporary TrustedHosts entries: $($addedTrustedHosts -join ', ')"
        }
    } catch {
        Write-Log "Could not clean up TrustedHosts: $($_.Exception.Message)" 'WARN'
    }
}

Write-Log "HTML report : $htmlPath"
Write-Log "JSON report : $jsonPath"
Write-Log "Instance CSV: $instanceCsvPath"
Write-Log "Database CSV: $databaseCsvPath"

Write-Host ""
Write-Host "============================================================"
Write-Host "SQL SERVER INVENTORY COMPLETE"
Write-Host "============================================================"
Write-Host "HTML : $htmlPath"
Write-Host "JSON : $jsonPath"
Write-Host "INST : $instanceCsvPath"
Write-Host "DB   : $databaseCsvPath"
Write-Host "LOG  : $logPath"
Write-Host ""
Write-Host "VMs        : $totalVMs"
Write-Host "Successful : $successfulVMs"
Write-Host "Failed     : $failedVMs"
Write-Host "Instances  : $totalInstances"
Write-Host "Databases  : $totalDatabases"
Write-Host "============================================================"
