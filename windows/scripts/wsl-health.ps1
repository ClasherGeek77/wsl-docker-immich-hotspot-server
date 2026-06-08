# wsl-health.ps1 — Non-blocking self-heal check, run every 5 min by a scheduled
# task. Ensures the keepalive anchor task is running and docker is up. Exits fast.
#
# If the keepalive task (AutoStartWSL) is not running, (re)start it. Then make a
# best-effort docker check. This is the "belt and suspenders" layer. Finally it
# re-applies the USB-modem ClampMss (runtime-only, resets on reboot).

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$Distro = 'Ubuntu-22.04'
$LogFile = 'C:\wsl-health.log'
$KeepaliveTask = 'AutoStartWSL'

function Log($msg) {
  ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $msg) | Out-File -FilePath $LogFile -Append -Encoding utf8
}

. (Join-Path $PSScriptRoot 'lib\net-tune.ps1')

# 1) Ensure the keepalive task is running.
$task = Get-ScheduledTask -TaskName $KeepaliveTask -ErrorAction SilentlyContinue
if ($task) {
  if ($task.State -ne 'Running') {
    Log ($KeepaliveTask + ' not running (state=' + $task.State + ') -> starting it.')
    Start-ScheduledTask -TaskName $KeepaliveTask
    Start-Sleep -Seconds 10
  }
} else {
  Log ('WARNING: ' + $KeepaliveTask + ' task not found.')
}

# 2) Best-effort docker check (do NOT block; short timeout via separate wsl call).
$active = (wsl.exe -d $Distro -u root -- bash -c 'systemctl is-active docker 2>/dev/null || echo down' 2>&1 | Out-String).Trim()
if ($active -notmatch 'active') {
  Log ('Docker not active (=' + $active + ') -> starting docker.service.')
  wsl.exe -d $Distro -u root -- bash -c 'systemctl start docker 2>&1 || (rm -f /var/run/docker.pid; setsid nohup dockerd >/var/log/dockerd-fallback.log 2>&1 </dev/null & disown)' 2>&1 | Out-Null
  Start-Sleep -Seconds 6
  $active2 = (wsl.exe -d $Distro -u root -- bash -c 'systemctl is-active docker 2>/dev/null || echo down' 2>&1 | Out-String).Trim()
  Log ('Docker after heal: ' + $active2)
} else {
  Log 'Docker active. OK.'
}

# 3) Re-apply ClampMss on the USB modem (runtime-only, resets on reboot).
Set-ModemClampMss -Log ${function:Log}
