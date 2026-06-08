# tcp-tune-hotspot.ps1
# Applies the TCP/QoS tuning that stabilises high-throughput streaming
# (TikTok, WhatsApp calls) over the Windows ICS hotspot fed by a USB modem.
#
# Topology this targets:
#   Phone -> [Wi-Fi Direct hotspot adapter] -> Windows ICS NAT -> [USB modem] -> Internet
#
# Why each setting (see docs/server-journal.md "TCP/Hotspot stability fix"):
#   - ClampMss          : USB modem MTU < 1500; without clamping, MSS=1460 packets
#                         fragment silently -> stalls. Clamp on BOTH hotspot + modem.
#   - autotuninglevel   : 'normal' over-grows RWIN past what ICS (ipnathlp.dll) tracks
#                         across the NAT boundary -> bufferbloat. 'restricted' adapts
#                         but stays bounded. (NOT 'disabled' = 64KB hard cap, too low.)
#   - ECN               : lets the CDN back off gracefully instead of hard-dropping.
#   - CTCP              : Compound TCP — better congestion control for LTE-style links
#                         with variable latency than the default.
#   - vboxnetflt unbind : VirtualBox's NDIS filter intercepts every hotspot packet and
#                         blocks RSC; the phone path doesn't need it.
#
# Persistence note: the global netsh settings persist in the registry across reboots.
# ClampMss + the NDIS unbind are runtime-only on the adapter object, so they are
# re-applied by:
#   - start-hotspot-now.ps1  (hotspot adapter, after each hotspot start)
#   - wsl-health.ps1         (USB modem, every 5 min)
# Run THIS script once for a fresh apply / manual re-apply.

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$LogFile = 'C:\hotspot-log.txt'
function Log($msg) { ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $msg) | Out-File -FilePath $LogFile -Append -Encoding utf8 }

Log '=== tcp-tune-hotspot.ps1 ==='

# 1) Global TCP settings (registry-backed; survive reboot).
netsh int tcp set global autotuninglevel=restricted | Out-Null
netsh int tcp set global ecncapability=enabled | Out-Null
netsh int tcp set supplemental template=Internet CongestionProvider=CTCP | Out-Null
Log 'Global: autotuning=restricted, ecn=enabled, provider=CTCP'

# 2) USB modem (Remote NDIS device): clamp MSS.
$modem = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like 'Remote NDIS*' -and $_.Status -eq 'Up' } | Select-Object -First 1
if ($modem) {
    Set-NetIPInterface -InterfaceAlias $modem.Name -ClampMss Enabled -ErrorAction SilentlyContinue
    Log ('ClampMss enabled on modem: ' + $modem.Name)
} else {
    Log 'WARN: USB modem (Remote NDIS) not found / not up.'
}

# 3) Hotspot virtual adapter: clamp MSS + drop the VirtualBox NDIS filter.
$hotspot = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like 'Microsoft Wi-Fi Direct Virtual Adapter*' -and $_.Status -eq 'Up' } | Select-Object -First 1
if ($hotspot) {
    Set-NetIPInterface -InterfaceAlias $hotspot.Name -ClampMss Enabled -ErrorAction SilentlyContinue
    Disable-NetAdapterBinding -Name $hotspot.Name -ComponentID vboxnetflt -ErrorAction SilentlyContinue
    Log ('ClampMss enabled + vboxnetflt unbound on hotspot: ' + $hotspot.Name)
} else {
    Log 'WARN: Wi-Fi Direct hotspot adapter not found / not up (start the hotspot first).'
}

Log 'tcp-tune-hotspot.ps1 done.'
Write-Output 'TCP tuning applied. See C:\hotspot-log.txt'
