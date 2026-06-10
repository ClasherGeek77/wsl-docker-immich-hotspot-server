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
        netsh interface ipv4 set subinterface $modem.Name mtu=1400 store=persistent | Out-Null
        Set-DnsClientServerAddress -InterfaceAlias $modem.Name -ServerAddresses ('1.1.1.1', '1.0.0.1') -ErrorAction SilentlyContinue
        & $Log ('ClampMss, MTU=1400, and Cloudflare DNS applied to modem: ' + $modem.Name)
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
        netsh interface ipv4 set subinterface $hotspot.Name mtu=1400 store=persistent | Out-Null
        Disable-NetAdapterBinding -Name $hotspot.Name -ComponentID vboxnetflt -ErrorAction SilentlyContinue
        & $Log ('TCP tuning and MTU=1400 applied to hotspot: ' + $hotspot.Name + ' (ClampMss=On, vboxnetflt unbound)')
    } else {
        & $Log 'Hotspot TCP tuning: Wi-Fi Direct adapter not up, skipped.'
    }
}

function Set-GlobalTcpTuning {
    # Registry-backed; these survive reboot. autotuning bounded for the ICS NAT,
    # ECN for graceful backoff, CUBIC for variable-latency LTE links.
    param([scriptblock]$Log = { param($m) })
    netsh int tcp set global autotuninglevel=normal | Out-Null
    netsh int tcp set global ecncapability=enabled | Out-Null
    netsh int tcp set global timestamps=enabled | Out-Null
    netsh int tcp set global pacingprofile=slowstart | Out-Null
    netsh int tcp set supplemental template=Internet CongestionProvider=CUBIC | Out-Null
    & $Log 'Global TCP: autotuning=normal, ecn=enabled, timestamps=enabled, pacing=slowstart, provider=CUBIC'

    # TTL Throttling Bypass (set DefaultTTL to 65 so it decrements to 64 at NAT boundary)
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'DefaultTTL' -Value 65 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' -Name 'DefaultTTL' -Value 65 -PropertyType DWord -Force | Out-Null
    & $Log 'TTL Bypass: DefaultTTL set to 65'

    # Nagle's & Delayed ACK Disable
    $interfaces = Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    foreach ($if in $interfaces) {
        if (Get-ItemProperty -Path $if.PSPath -Name 'TcpAckFrequency' -ErrorAction SilentlyContinue) {
            Set-ItemProperty -Path $if.PSPath -Name 'TcpAckFrequency' -Value 1 -Force
        } else {
            New-ItemProperty -Path $if.PSPath -Name 'TcpAckFrequency' -Value 1 -PropertyType DWord -Force | Out-Null
        }
        if (Get-ItemProperty -Path $if.PSPath -Name 'TCPNoDelay' -ErrorAction SilentlyContinue) {
            Set-ItemProperty -Path $if.PSPath -Name 'TCPNoDelay' -Value 1 -Force
        } else {
            New-ItemProperty -Path $if.PSPath -Name 'TCPNoDelay' -Value 1 -PropertyType DWord -Force | Out-Null
        }
    }
    & $Log 'Latency Optimization: Delayed ACK and Nagle disabled'

    # System Network Throttling Disable
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'NetworkThrottlingIndex' -Value 4294967295 -Force | Out-Null
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'SystemResponsiveness' -Value 0 -Force | Out-Null
    & $Log 'System: Network Throttling disabled'

    # Wi-Fi Adapter Optimizations (MIMO, Transmit Power, Power Plan)
    powercfg /SETACVALUEINDEX SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 | Out-Null
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 | Out-Null
    powercfg /SETACTIVE SCHEME_CURRENT | Out-Null

    if (Get-NetAdapter -Name 'Wi-Fi' -ErrorAction SilentlyContinue) {
        Set-NetAdapterAdvancedProperty -Name 'Wi-Fi' -RegistryKeyword 'MIMOPowerSaveMode' -RegistryValue '3' -ErrorAction SilentlyContinue | Out-Null
        Set-NetAdapterAdvancedProperty -Name 'Wi-Fi' -RegistryKeyword 'ThroughputBoosterEnabled' -RegistryValue '1' -ErrorAction SilentlyContinue | Out-Null
    }
    & $Log 'Wi-Fi: Power Plan set to Max Performance, MIMO SMPS disabled, Throughput Booster enabled'

    # Disable hotspot timeouts (set PeerlessTimeout and PublicConnectionTimeout to 1440 min)
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\icssvc\Settings' -Name 'PeerlessTimeout' -Value 1440 -PropertyType DWORD -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\icssvc\Settings' -Name 'PublicConnectionTimeout' -Value 1440 -PropertyType DWORD -Force | Out-Null
    Restart-Service -Name icssvc -Force -ErrorAction SilentlyContinue
    & $Log 'Hotspot Timeout: disabled (PeerlessTimeout=1440, PublicConnectionTimeout=1440)'
}
