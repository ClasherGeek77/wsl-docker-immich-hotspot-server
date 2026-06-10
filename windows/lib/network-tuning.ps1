# network-tuning.ps1 — shared TCP/QoS tuning helpers.
# Dot-source this from the hotspot / health / standalone scripts so the ClampMss +
# vboxnetflt logic lives in ONE place. Behavior is identical to the inlined versions
# it replaces. Each function is self-contained and safe to call repeatedly.

function Set-ModemClampMss {
    # USB LTE modem shows up as a "Remote NDIS" adapter. ClampMss is runtime-only and
    # resets on reboot, so callers (e.g. the 5-min health task) re-apply it.
    param([scriptblock]$Log = { param($m) })
    $modem = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like 'Remote NDIS*' -and $_.Status -eq 'Up' } | Select-Object -First 1
    if ($modem) {
        Set-NetIPInterface -InterfaceAlias $modem.Name -ClampMss Enabled -ErrorAction SilentlyContinue
        & $Log ('ClampMss applied to modem: ' + $modem.Name)
    } else {
        & $Log 'ClampMss: USB modem (Remote NDIS) not up, skipped.'
    }
}

function Set-HotspotTcpTuning {
    # Wi-Fi Direct hotspot adapter gets a new name index each time it is recreated, so
    # this is re-applied after every hotspot start. ClampMss + drop the VirtualBox NDIS
    # filter that otherwise intercepts every hotspot packet and blocks RSC.
    param([scriptblock]$Log = { param($m) })
    $hotspot = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like 'Microsoft Wi-Fi Direct Virtual Adapter*' -and $_.Status -eq 'Up' } | Select-Object -First 1
    if ($hotspot) {
        Set-NetIPInterface -InterfaceAlias $hotspot.Name -ClampMss Enabled -ErrorAction SilentlyContinue
        Disable-NetAdapterBinding -Name $hotspot.Name -ComponentID vboxnetflt -ErrorAction SilentlyContinue
        & $Log ('TCP tuning applied to hotspot: ' + $hotspot.Name + ' (ClampMss=On, vboxnetflt unbound)')
    } else {
        & $Log 'Hotspot TCP tuning: Wi-Fi Direct adapter not up, skipped.'
    }
}

function Set-GlobalTcpTuning {
    # Registry-backed; these survive reboot. autotuning bounded for the ICS NAT,
    # ECN for graceful backoff, CTCP for variable-latency LTE links.
    param([scriptblock]$Log = { param($m) })
    netsh int tcp set global autotuninglevel=restricted | Out-Null
    netsh int tcp set global ecncapability=enabled | Out-Null
    netsh int tcp set supplemental template=Internet CongestionProvider=CTCP | Out-Null
    & $Log 'Global TCP: autotuning=restricted, ecn=enabled, provider=CTCP'

    # Disable hotspot timeouts (set PeerlessTimeout and PublicConnectionTimeout to 1440 min)
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\icssvc\Settings' -Name 'PeerlessTimeout' -Value 1440 -PropertyType DWORD -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\icssvc\Settings' -Name 'PublicConnectionTimeout' -Value 1440 -PropertyType DWORD -Force | Out-Null
    Restart-Service -Name icssvc -Force -ErrorAction SilentlyContinue
    & $Log 'Hotspot Timeout: disabled (PeerlessTimeout=1440, PublicConnectionTimeout=1440)'
}
