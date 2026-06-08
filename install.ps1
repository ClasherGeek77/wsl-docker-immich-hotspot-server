<#
  install.ps1 — one-click installer for the WSL+Docker+Immich+zrok+hotspot home server.

  Run from an ELEVATED PowerShell, from the root of this repo:

      powershell -ExecutionPolicy Bypass -File .\install.ps1

  What it does (interactive + safe; idempotent — re-run any time):
    1. Checks prerequisites (admin, WSL distro, Docker in WSL).
    2. Stages the Windows scripts to C:\home-server\ (runtime\ + setup\ + lib\).
    3. Ensures immich\.env exists (prompts for the secret values if missing).
    4. Registers the scheduled tasks (keepalive anchor + health watchdog).
    5. Brings up the Immich/zrok Docker stack.
    6. Starts the hotspot and applies TCP tuning.
    7. Prints a health summary.

  Nothing here is destructive: existing .env is never overwritten, tasks are
  re-registered idempotently, and `docker compose up -d` is a no-op if already up.
#>

[CmdletBinding()]
param(
  [string]$InstallRoot = 'C:\home-server',
  [string]$Distro      = 'Ubuntu-22.04',
  [switch]$SkipDocker,
  [switch]$SkipHotspot
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

function Step($n, $msg) { Write-Host "`n[$n] $msg" -ForegroundColor Cyan }
function Ok($msg)       { Write-Host "    OK  $msg" -ForegroundColor Green }
function Warn($msg)     { Write-Host "    !!  $msg" -ForegroundColor Yellow }

# --- 1. Prerequisites -------------------------------------------------------
Step 1 'Checking prerequisites'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) { throw 'Must run as Administrator (needed for scheduled tasks + netsh).' }
Ok 'Running elevated.'

if (-not (wsl.exe -l -q 2>$null | Select-String -SimpleMatch $Distro)) {
  throw "WSL distro '$Distro' not found. Install it first: wsl --install -d $Distro"
}
Ok "WSL distro '$Distro' present."

$dockerActive = (wsl.exe -d $Distro -u root -- bash -c 'systemctl is-active docker 2>/dev/null || echo down' 2>&1 |
                 Out-String).Trim()
if ($dockerActive -notmatch 'active') { Warn "Docker not active yet in WSL (=$dockerActive) — the keepalive task will start it." }
else { Ok 'Docker active in WSL.' }

# --- 2. Stage scripts to InstallRoot ---------------------------------------
Step 2 "Staging Windows scripts to $InstallRoot"
foreach ($sub in 'runtime','setup','lib','logs') {
  New-Item -ItemType Directory -Path (Join-Path $InstallRoot $sub) -Force | Out-Null
}
Copy-Item (Join-Path $repo 'windows\runtime\*') (Join-Path $InstallRoot 'runtime') -Force
Copy-Item (Join-Path $repo 'windows\setup\*')   (Join-Path $InstallRoot 'setup')   -Force
Copy-Item (Join-Path $repo 'windows\lib\*')     (Join-Path $InstallRoot 'lib')     -Force
Ok "Staged runtime\, setup\, lib\ (dot-source relationship preserved)."

# --- 3. Ensure immich\.env --------------------------------------------------
Step 3 'Ensuring immich\.env'
$envPath     = Join-Path $repo 'immich\.env'
$envExample  = Join-Path $repo 'immich\.env.example'
if (Test-Path $envPath) {
  Ok '.env already exists — leaving it untouched.'
} else {
  Warn '.env not found — creating from .env.example and prompting for secrets.'
  $content = Get-Content $envExample -Raw
  foreach ($key in 'DB_PASSWORD','ZROK_ENABLE_TOKEN','ZROK_SHARE_NAME','HOTSPOT_SSID','HOTSPOT_PASSPHRASE') {
    $val = Read-Host "    Enter $key"
    $content = $content -replace "(?m)^$key=.*$", "$key=$val"
  }
  Set-Content -Path $envPath -Value $content -Encoding UTF8
  Ok '.env written (gitignored — never committed).'
}

# --- 4. Register scheduled tasks -------------------------------------------
Step 4 'Registering scheduled tasks (keepalive anchor + health watchdog)'
$hostUser = "$env:USERDOMAIN\$env:USERNAME"
& (Join-Path $InstallRoot 'setup\register-tasks.ps1') `
    -RuntimeDir (Join-Path $InstallRoot 'runtime') -HostUser $hostUser
Ok "Tasks registered for $hostUser, pointing at $InstallRoot\runtime."

# --- 5. Immich / zrok stack -------------------------------------------------
if (-not $SkipDocker) {
  Step 5 'Bringing up the Immich/zrok Docker stack'
  $immichWsl = (wsl.exe -d $Distro -u root -- wslpath -a "$(Join-Path $repo 'immich')" 2>$null).Trim()
  if (-not $immichWsl) { $immichWsl = '/mnt/d/home-server/immich' }  # fallback to known host path
  wsl.exe -d $Distro -u root -- bash -c "cd '$immichWsl' && docker compose up -d" 2>&1 | Write-Host
  Ok 'docker compose up -d issued.'
} else { Warn 'Skipping Docker stack (-SkipDocker).' }

# --- 6. Hotspot + TCP tuning ------------------------------------------------
if (-not $SkipHotspot) {
  Step 6 'Starting hotspot + applying TCP tuning'
  & (Join-Path $InstallRoot 'runtime\hotspot-start.ps1')
  & (Join-Path $InstallRoot 'setup\tcp-tune.ps1')
  Ok 'Hotspot start + TCP tuning invoked.'
} else { Warn 'Skipping hotspot (-SkipHotspot).' }

# --- 7. Health summary ------------------------------------------------------
Step 7 'Health summary'
Get-ScheduledTask | Where-Object { $_.TaskName -match 'WSL|Hotspot|Docker' } |
  Select-Object TaskName, State | Format-Table -AutoSize | Out-String | Write-Host
$d = (wsl.exe -d $Distro -u root -- bash -c 'systemctl is-active docker 2>/dev/null || echo down' 2>&1 | Out-String).Trim()
Write-Host ("    Docker in WSL : {0}" -f $d)
Write-Host ("    netsh TCP     : {0}" -f ((netsh int tcp show global | Select-String 'Auto-Tuning|ECN') -join '; '))
Write-Host "`nDone. See logs in $InstallRoot\logs and C:\*.log" -ForegroundColor Green
