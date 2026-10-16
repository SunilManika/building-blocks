# Downloads a zip, verifies its SHA-256, and extracts it to -Dest (Windows PowerShell 5.1 compatible).
# If the archive has a single top-level folder (for example node-v22.x-win-x64), that folder's contents are used.
param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Sha256,
    [Parameter(Mandatory)][string]$Dest
)
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$zip = Join-Path $env:TEMP ([IO.Path]::GetFileName($Url))
Write-Host "Downloading $Url"
Invoke-WebRequest -Uri $Url -OutFile $zip -UseBasicParsing

$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash
if ($actual -ne $Sha256.ToUpper()) { throw "SHA-256 mismatch for $Url`n expected $Sha256`n actual   $actual" }

$tmp = Join-Path $env:TEMP ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
# tar.exe (bsdtar) ships with Windows Server 2019+ and is much faster than Expand-Archive on large zips.
tar.exe -xf $zip -C $tmp
if ($LASTEXITCODE -ne 0) { throw "Extraction failed for $zip" }

$items = @(Get-ChildItem -LiteralPath $tmp -Force)
$src = if ($items.Count -eq 1 -and $items[0].PSIsContainer) { $items[0].FullName } else { $tmp }
New-Item -ItemType Directory -Path $Dest -Force | Out-Null
Move-Item -Path (Join-Path $src '*') -Destination $Dest -Force

Remove-Item -LiteralPath $zip -Force
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Installed to $Dest"
