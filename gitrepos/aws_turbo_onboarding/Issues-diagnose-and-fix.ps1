# ============================================================
# Azure Windows VM - Diagnose & fix turbowmiXX WinRM accounts
# Targets: d10 (172.16.0.7), d12 (172.16.0.6),
#          d14 (172.16.0.9), d18 (172.16.0.11)
# Run from: https://shell.azure.com/
# ============================================================

$ErrorActionPreference = "Stop"

$resourceGroup = "rg-6a83193ee0f27dc9c69e3205-ThDAE-1"

# Per-VM account mapping (matches config.json)
$vmUsers = [ordered]@{
    "turbo-wmi-win-d10" = "turbowmid10"
    "turbo-wmi-win-d12" = "turbowmid12"
    "turbo-wmi-win-d14" = "turbowmid14"
    "turbo-wmi-win-d18" = "turbowmid18"   # adjust name if different
}

$password = "TrbWmi#2026!X9@Q7"

# -- Step 1: DIAGNOSE - check account + WinRM + registry on each VM ----------
$diagScript = @'
param([string]$AccountName)
$ErrorActionPreference = "SilentlyContinue"

# Account state
$user    = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
$exists  = $null -ne $user
$enabled = if ($exists) { $user.Enabled } else { $false }
$locked  = if ($exists) {
    $adsi = [ADSI]("WinNT://./$AccountName,user")
    [bool]$adsi.InvokeGet("IsAccountLocked")
} else { $false }

# Group memberships
$inAdmins  = $false
$inWinRM   = $false
if ($exists) {
    $inAdmins = (Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -like "*$AccountName" }) -ne $null
    foreach ($grp in @("WinRMRemoteWMIUsers__","Remote Management Users")) {
        if (Get-LocalGroupMember -Group $grp -Member $AccountName -ErrorAction SilentlyContinue) {
            $inWinRM = $true; break
        }
    }
}

# Registry - LocalAccountTokenFilterPolicy
$laftp = (Get-ItemProperty `
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy

# WinRM service
$winrm = (Get-Service WinRM -ErrorAction SilentlyContinue).Status

[PSCustomObject]@{
    Computer   = $env:COMPUTERNAME
    Account    = $AccountName
    Exists     = $exists
    Enabled    = $enabled
    Locked     = $locked
    InAdmins   = $inAdmins
    InWinRM    = $inWinRM
    LAFTP      = $laftp   # must be 1
    WinRM      = "$winrm"
} | ConvertTo-Json -Compress
'@

Write-Host "`n===== STEP 1: DIAGNOSE =====" -ForegroundColor Cyan
$diagResults = foreach ($vmName in $vmUsers.Keys) {
    $acct = $vmUsers[$vmName]
    Write-Host "  Checking $vmName ($acct)..." -NoNewline
    try {
        $r = Invoke-AzVMRunCommand -ResourceGroupName $resourceGroup -VMName $vmName `
                -CommandId RunPowerShellScript `
                -Parameter @{ AccountName = $acct } `
                -ScriptString $diagScript -ErrorAction Stop
        $out = ($r.Value | Where-Object { $_.Code -eq "ComponentStatus/StdOut/succeeded" } |
                Select-Object -First 1).Message
        $json = $out -split "`r?`n" | Where-Object { $_.Trim().StartsWith("{") } | Select-Object -Last 1
        $d    = $json | ConvertFrom-Json
        Write-Host " done" -ForegroundColor Green
        [PSCustomObject]@{
            VM       = $vmName
            Account  = $acct
            Exists   = $d.Exists
            Enabled  = $d.Enabled
            Locked   = $d.Locked
            InAdmins = $d.InAdmins
            InWinRM  = $d.InWinRM
            LAFTP    = $d.LAFTP
            WinRM    = $d.WinRM
        }
    } catch {
        Write-Host " ERROR: $($_.Exception.Message)" -ForegroundColor Red
        [PSCustomObject]@{ VM=$vmName; Account=$acct; Exists='ERR'; Enabled='ERR'
                           Locked='ERR'; InAdmins='ERR'; InWinRM='ERR'; LAFTP='ERR'; WinRM='ERR' }
    }
}

$diagResults | Format-Table -AutoSize

# -- Step 2: FIX - create/unlock account + set LocalAccountTokenFilterPolicy -
$fixScript = @'
param([string]$AccountName, [string]$Password)
$ErrorActionPreference = "Stop"
$log = @()

# 1. Create or update account
$secPwd = ConvertTo-SecureString $Password -AsPlainText -Force
$user   = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
if (-not $user) {
    New-LocalUser -Name $AccountName -Password $secPwd `
                  -PasswordNeverExpires -Description "Turbonomic WMI collector" | Out-Null
    $log += "Created user $AccountName"
} else {
    Set-LocalUser -Name $AccountName -Password $secPwd -PasswordNeverExpires $true
    $log += "Updated password for $AccountName"
}

# 2. Enable and unlock
Enable-LocalUser -Name $AccountName
$adsi = [ADSI]("WinNT://./$AccountName,user")
if ([bool]$adsi.InvokeGet("IsAccountLocked")) {
    $adsi.InvokeSet("IsAccountLocked", $false); $adsi.SetInfo()
    $log += "Unlocked $AccountName"
}

# 3. Add to Administrators (required for remote WMI)
$inAdmins = (Get-LocalGroupMember "Administrators" -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -like "*$AccountName" }) -ne $null
if (-not $inAdmins) {
    Add-LocalGroupMember -Group "Administrators" -Member $AccountName
    $log += "Added $AccountName to Administrators"
}

# 4. Add to WinRM group
foreach ($grp in @("WinRMRemoteWMIUsers__","Remote Management Users")) {
    if (Get-LocalGroup -Name $grp -ErrorAction SilentlyContinue) {
        $already = (Get-LocalGroupMember $grp -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "*$AccountName" }) -ne $null
        if (-not $already) {
            Add-LocalGroupMember -Group $grp -Member $AccountName
            $log += "Added $AccountName to $grp"
        }
        break
    }
}

# 5. LocalAccountTokenFilterPolicy = 1
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$current = (Get-ItemProperty $regPath -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy
if ($current -ne 1) {
    Set-ItemProperty $regPath -Name LocalAccountTokenFilterPolicy -Value 1 -Type DWord
    $log += "Set LocalAccountTokenFilterPolicy = 1  (restart required)"
}

# 6. Ensure WinRM is running
$svc = Get-Service WinRM -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne "Running") {
    Start-Service WinRM
    $log += "Started WinRM service"
}

[PSCustomObject]@{ Computer=$env:COMPUTERNAME; Account=$AccountName; Steps=$log -join " | " } |
    ConvertTo-Json -Compress
'@

Write-Host "`n===== STEP 2: FIX =====" -ForegroundColor Cyan
$fixResults = foreach ($vmName in $vmUsers.Keys) {
    $acct = $vmUsers[$vmName]
    Write-Host "  Fixing $vmName ($acct)..." -NoNewline
    try {
        $r = Invoke-AzVMRunCommand -ResourceGroupName $resourceGroup -VMName $vmName `
                -CommandId RunPowerShellScript `
                -Parameter @{ AccountName = $acct; Password = $password } `
                -ScriptString $fixScript -ErrorAction Stop
        $out = ($r.Value | Where-Object { $_.Code -eq "ComponentStatus/StdOut/succeeded" } |
                Select-Object -First 1).Message
        $json = $out -split "`r?`n" | Where-Object { $_.Trim().StartsWith("{") } | Select-Object -Last 1
        $d    = $json | ConvertFrom-Json
        Write-Host " done" -ForegroundColor Green
        [PSCustomObject]@{ VM=$vmName; Account=$acct; Steps=$d.Steps }
    } catch {
        Write-Host " ERROR: $($_.Exception.Message)" -ForegroundColor Red
        [PSCustomObject]@{ VM=$vmName; Account=$acct; Steps="FAILED: $($_.Exception.Message)" }
    }
}

$fixResults | Format-Table -AutoSize -Wrap

# -- Step 3: RESTART - apply LocalAccountTokenFilterPolicy -------------------
Write-Host "`n===== STEP 3: RESTART VMs =====" -ForegroundColor Cyan
Write-Host "LocalAccountTokenFilterPolicy requires a restart to take effect." -ForegroundColor Yellow
Write-Host "Restarting VMs now..." -ForegroundColor Yellow

foreach ($vmName in $vmUsers.Keys) {
    Write-Host "  Restarting $vmName..." -NoNewline
    try {
        Restart-AzVM -ResourceGroupName $resourceGroup -Name $vmName -Force | Out-Null
        Write-Host " done" -ForegroundColor Green
    } catch {
        Write-Host " ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`nWait ~2 minutes for VMs to boot, then re-run the collection." -ForegroundColor Green
