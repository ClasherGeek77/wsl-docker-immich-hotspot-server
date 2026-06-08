# pc-remote — Fixes Applied 2026-06-06

## Root cause (WSL/Docker not auto-starting; zrok 502)
WSL shuts down its VM when no Linux session is attached -> kills dockerd + all
containers -> zrok 502. The OLD tasks never fired because:
  - SYSTEM-context WSL is BLOCKED by WSL itself (WSL_E_LOCAL_SYSTEM_NOT_SUPPORTED).
  - Interactive-logon tasks never ran because the headless boot has NO interactive
    session (query user -> "No User exists for *").
  - The "Failed to start systemd user session for root" message is COSMETIC; once
    WSL is up a few seconds, systemd is `running`, dbus is up, and docker.service
    (already `enabled`) starts fine.

## Solution
- C:\wsl-up.ps1     : boots WSL, ensures docker (systemd; falls back to direct
                      dockerd), then BLOCKS in a foreground `wsl ... sleep` loop =
                      the keepalive ANCHOR that holds the WSL VM open forever.
- C:\wsl-health.ps1 : every 5 min, ensures AutoStartWSL is Running and docker active.

## Scheduled tasks (all run as ted / LogonType=Password = "run whether logged on or not")
- AutoStartWSL    : triggers AtStartup + AtLogon(ted) -> runs wsl-up.ps1 (keepalive).
                    RestartCount 999 / 1-min interval, no time limit, IgnoreNew.
- WSLDockerHealth : every 5 min -> wsl-health.ps1.
- AutoHotspotBoot : UNCHANGED (works).
- DELETED dead tasks: AutoHotspot, AutoStartWSLBoot, WSLKeepAlive (all SYSTEM/interactive, never ran).

## Verified
- 90s idle with no SSH activity: WSL stayed up, containers "Up N minutes" (no cold reboot).
- https://<your-share>.share.zrok.io -> HTTP 200 (was 502).
- Logs: C:\wsl-up.log , C:\wsl-health.log

## MAC pin (NOT fixable)
NetworkAddress=<redacted-mac> IS set on both Wi-Fi Direct instance keys (0003,0004) but
the Microsoft Wi-Fi Direct Virtual Adapter driver IGNORES it; live MAC stays
XX-XX-XX-XX-XX-XX (derived from physical Wi-Fi YY-YY-YY-YY-YY-YY w/ locally-admin bit).
disable/enable DESTROYS the virtual adapter (recreate via C:\start-hotspot-now.ps1).
Left registry value in place; hotspot works regardless of MAC.

## Hotspot hardening (added after reboot test)
Reboot revealed `AutoHotspotBoot` reports 0x0 but tethering can be OFF: the old
script fired StartTetheringAsync once (fire-and-forget) at boot+15s before the USB
modem profile was ready -> silent no-op. Hardened C:\start-hotspot-now.ps1 to:
  - wait up to ~90s for an InternetAccess profile (modem warmup),
  - then Start + VERIFY + RETRY (5 attempts) until TetheringOperationalState=On.
Original saved as C:\start-hotspot-now.ps1.bak. Log: C:\hotspot-log.txt.
Gotcha fixed: `$attempt:` parses as a PS drive ref -> use string concatenation.

## Reboot validation (2026-06-06 21:15)
Real reboot. AutoStartWSL fired AtStartup (LastRun boot+21s), docker active,
8 containers up, zrok HTTP 200 -- all with ZERO manual intervention. Hotspot
needed the hardened retry (now applied). Autologon DOES create an interactive
console session on a clean boot (query user shows ted Active).
