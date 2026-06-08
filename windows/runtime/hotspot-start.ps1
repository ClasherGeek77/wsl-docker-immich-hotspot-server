# hotspot-start.ps1
# Starts the hotspot - works as SYSTEM or interactive.
# HARDENED 2026-06-06: waits for an internet profile (USB modem may be slow at
# boot), then verifies tethering actually reaches On and RETRIES, instead of
# fire-and-forget (which silently no-ops if the modem/radio isn't ready yet).
# SSID/passphrase come from $env:HOTSPOT_SSID / $env:HOTSPOT_PASSPHRASE.
# Logs to C:\hotspot-log.txt

$logFile = "C:\hotspot-log.txt"
function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts - $msg" | Out-File -Append -FilePath $logFile -Encoding UTF8
}

. (Join-Path $PSScriptRoot '..\lib\network-tuning.ps1')

Log "=== hotspot-start.ps1 (hardened) ==="

try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime] | Out-Null
    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime] | Out-Null

    # 1) Wait up to ~90s for an internet-providing profile (modem warmup at boot).
    $targetProfile = $null
    for ($w = 0; $w -lt 30; $w++) {
        $allProfiles = [Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles()
        foreach ($p in $allProfiles) {
            $level = $p.GetNetworkConnectivityLevel()
            if ($level -eq "InternetAccess" -and $p.ProfileName -ne "Tailscale") {
                $targetProfile = $p
                break
            }
        }
        if ($targetProfile) { Log "Internet profile: $($targetProfile.ProfileName)"; break }
        Start-Sleep -Seconds 3
    }

    if (-not $targetProfile) { Log "ERROR: No internet profile found after wait"; return }

    $tm = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($targetProfile)

    # Already on? done.
    if ($tm.TetheringOperationalState -eq 'On') { Log "Tethering already On. Clients=$($tm.ClientCount)"; return }

    # Configure SSID/passphrase once.
    try {
        $config = $tm.GetCurrentAccessPointConfiguration()
        $config.Ssid = $(if ($env:HOTSPOT_SSID) { $env:HOTSPOT_SSID } else { "MyHotspot" })
        $config.Passphrase = $(if ($env:HOTSPOT_PASSPHRASE) { $env:HOTSPOT_PASSPHRASE } else { throw "Set $env:HOTSPOT_PASSPHRASE before running" })
        $tm.ConfigureAccessPointAsync($config) | Out-Null
        Start-Sleep -Seconds 3
    } catch { Log "Configure warn: $_" }

    # 2) Start + verify + retry until On (fire-and-forget can't be awaited on this build).
    $on = $false
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        # Re-create manager each attempt in case the profile/adapter churned.
        try {
            $conn = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
            if ($conn) { $tm = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($conn) }
        } catch {}
        if ($tm.TetheringOperationalState -eq 'On') { $on = $true; break }
        Log ("Attempt " + $attempt + ": state=" + $tm.TetheringOperationalState + " -> StartTetheringAsync")
        try { $tm.StartTetheringAsync() | Out-Null } catch { Log "Start warn: $_" }
        # Poll up to ~20s for it to flip On.
        for ($k = 0; $k -lt 10; $k++) {
            Start-Sleep -Seconds 2
            if ($tm.TetheringOperationalState -eq 'On') { $on = $true; break }
        }
        if ($on) { break }
    }

    if ($on) {
        Log "Tethering On. Clients=$($tm.ClientCount)/$($tm.MaxClientCount)"
        $virtual = Get-NetAdapter | Where-Object { $_.Name -match "Local Area" } | Select-Object -First 1
        if ($virtual) { Log "Virtual adapter: $($virtual.Name) ($($virtual.Status)) MAC=$($virtual.MacAddress)" }
        # Re-apply TCP/QoS tuning to the freshly-(re)created hotspot adapter.
        Set-HotspotTcpTuning -Log ${function:Log}
    } else {
        Log "ERROR: Tethering did not reach On after retries (state=$($tm.TetheringOperationalState))"
    }
} catch {
    Log "ERROR: $_"
}
