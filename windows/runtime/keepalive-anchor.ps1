# keepalive-anchor.ps1 — Boot WSL, ensure Docker, then BLOCK as the keepalive anchor.
#
# Root cause addressed: WSL shuts down its VM when no Linux session is attached,
# which kills dockerd + all containers (=> zrok 502). systemd starts docker fine
# once WSL is up (docker.service is enabled); the only missing piece is keeping
# WSL alive. A backgrounded/detached process does NOT survive (WSL tears down the
# session). The reliable anchor is a FOREGROUND, long-lived `wsl ... sleep` owned
# by this script's own process. When launched by Task Scheduler, that process is
# independent of any login/SSH session and persists.
#
# This script is meant to be the action of a scheduled task that runs continuously.
# It is also safe to run from the health task: if an anchor is already running it
# starts another harmless one (sleep), but the health task should normally just
# call health-watchdog.ps1 (non-blocking) instead. See deployment notes.

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$Distro = 'Ubuntu-22.04'
$LogFile = 'C:\wsl-up.log'

function Log($msg) {
  $line = ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $msg)
  $line | Out-File -FilePath $LogFile -Append -Encoding utf8
}

function WslBash([string]$cmd) {
  return (wsl.exe -d $Distro -u root -- bash -c $cmd 2>&1 | Out-String)
}

function Ensure-Docker {
  # Wait for systemd docker.service; start it; fall back to direct dockerd.
  for ($i = 0; $i -lt 20; $i++) {
    if ((WslBash 'systemctl is-active docker 2>/dev/null').Trim() -eq 'active') { return 'active-systemd' }
    Start-Sleep -Seconds 2
  }
  WslBash 'systemctl start docker 2>&1' | Out-Null
  Start-Sleep -Seconds 4
  if ((WslBash 'systemctl is-active docker 2>/dev/null').Trim() -eq 'active') { return 'started-systemd' }
  # Fallback: direct dockerd (no systemd dependency).
  WslBash 'pgrep dockerd >/dev/null 2>&1 || (rm -f /var/run/docker.pid; setsid nohup dockerd >/var/log/dockerd-fallback.log 2>&1 </dev/null & disown)' | Out-Null
  Start-Sleep -Seconds 8
  if ((WslBash 'docker info --format "{{.ServerVersion}}" 2>&1') -match '^\d') { return 'fallback-dockerd' }
  return 'FAILED'
}

Log '=== keepalive-anchor start ==='

# Bring docker up.
$state = Ensure-Docker
Log ('Docker state: ' + $state)
$ps = WslBash "docker ps --format '{{.Names}}: {{.Status}}' 2>&1"
Log ('Containers:' + "`n" + $ps.Trim())

# BLOCK as the anchor. This foreground wsl invocation holds the WSL VM open for
# as long as this process lives. Task Scheduler keeps this process running and
# will restart the task if it ever exits. The inner loop also re-asserts docker
# every 60s so a crashed dockerd self-heals without waiting for the 5-min task.
Log 'Entering keepalive anchor loop.'
while ($true) {
  # Foreground blocking call: if WSL is up, `sleep 60` blocks here 60s; if WSL
  # was torn down, this re-boots it. Either way the VM is held open.
  wsl.exe -d $Distro -u root -- bash -c 'pgrep dockerd >/dev/null 2>&1 || systemctl start docker >/dev/null 2>&1 || true; sleep 60' 2>&1 | Out-Null
}
