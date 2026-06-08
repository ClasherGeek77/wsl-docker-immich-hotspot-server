# tcp-tune.ps1
# One-shot TCP/QoS tuning for the ICS hotspot fed by a USB modem (stabilises TikTok
# scrolling / WhatsApp calls). The actual logic lives in lib/network-tuning.ps1 — this script
# just applies all three pieces and logs. See docs/server-journal.md "TCP/Hotspot
# stability fix" for the root-cause analysis, and docs/hardware.md for why a cheap
# modem needs this at all.
#
# Persistence: the global netsh bits are registry-backed (survive reboot). The
# per-adapter ClampMss / vboxnetflt bits are runtime-only and are re-applied by
# hotspot-start.ps1 (hotspot) and health-watchdog.ps1 (modem).

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$LogFile = 'C:\hotspot-log.txt'
function Log($msg) { ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $msg) | Out-File -FilePath $LogFile -Append -Encoding utf8 }

. (Join-Path $PSScriptRoot '..\lib\network-tuning.ps1')

Log '=== tcp-tune.ps1 ==='
Set-GlobalTcpTuning  -Log ${function:Log}
Set-ModemClampMss    -Log ${function:Log}
Set-HotspotTcpTuning -Log ${function:Log}
Log 'tcp-tune.ps1 done.'
Write-Output 'TCP tuning applied. See C:\hotspot-log.txt'
