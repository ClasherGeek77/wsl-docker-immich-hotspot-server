# pc-remote - Server Journal

Machine: <hostname> (Windows 10 IoT Enterprise LTSC, build 19044)
SSH alias: pc-remote | Tailscale IP: <tailscale-ip> | User: ted

---

## Current state (verified 2026-06-06)

| System | State | Notes |
|--------|-------|-------|
| WSL (Ubuntu-22.04) | Running | Kept alive by AutoStartWSL keepalive anchor |
| Docker | active (systemd) | docker.service enabled; 8 containers |
| Immich + zrok | https://<your-share>.share.zrok.io = HTTP 200 | was 502 before fix |
| Hotspot | On (SSID ThienServer) | Hardened retry script |
| Wi-Fi Direct MAC | XX-XX-XX-XX-XX-XX | Persistent across reboots (driver-derived) |

Validated across 2 reboots: WSL/Docker/zrok/hotspot all auto-recover, zero manual steps.

---

## Scheduled tasks

| Task | Runs as | Trigger | Purpose |
|------|---------|---------|---------|
| AutoStartWSL | ted / Password (run whether logged on or not) | AtStartup + AtLogon | Boots WSL, ensures Docker, BLOCKS as keepalive anchor (holds WSL VM open forever). RestartCount 999, no time limit. |
| WSLDockerHealth | ted / Password | Every 5 min | Ensures AutoStartWSL is Running and docker active (self-heal). |
| AutoHotspotBoot | SYSTEM | AtStartup +15s | Runs start-hotspot-now.ps1 (hardened). |

Deleted dead tasks: AutoHotspot, AutoStartWSLBoot, WSLKeepAlive (all SYSTEM/Interactive, never ran).

---

## Scripts on C:\

- **C:\wsl-up.ps1** - boots WSL, ensures docker (systemd; falls back to direct `dockerd`), then blocks in a `wsl ... sleep` loop = the keepalive ANCHOR. Log: C:\wsl-up.log
- **C:\wsl-health.ps1** - 5-min self-heal check. Log: C:\wsl-health.log
- **C:\start-hotspot-now.ps1** - HARDENED: waits up to ~90s for an InternetAccess profile, then Start+VERIFY+RETRY until tethering = On. Log: C:\hotspot-log.txt. Original at .bak
- **C:\FIXES_APPLIED.md** - detailed root-cause writeup.

---

## Root causes (why it was broken)

1. **zrok 502 / Docker down**: WSL tears down its VM when no Linux session is attached
   -> kills dockerd -> kills containers. Fix: keepalive anchor holds WSL open.
2. **Boot tasks never fired**:
   - SYSTEM-context WSL is BLOCKED by WSL itself (WSL_E_LOCAL_SYSTEM_NOT_SUPPORTED).
   - Interactive-logon tasks didn't run when the box had a stale/disconnected session.
   - Fix: run as ted with LogonType=Password ("run whether logged on or not").
3. "Failed to start systemd user session for root" is COSMETIC - once WSL is up a few
   seconds, systemd is `running`, dbus is up, docker.service starts fine.
4. **Hotspot Off after reboot**: old fire-and-forget StartTetheringAsync ran before the
   USB modem profile was ready. Fix: hardened script waits + verifies + retries.

## MAC note
Wi-Fi Direct virtual adapter MAC = XX-XX-XX-XX-XX-XX, derived from physical Wi-Fi NIC
YY-YY-YY-YY-YY-YY (locally-admin bit flip). PERSISTENT across reboots. The driver
ignores the NetworkAddress registry override, so 02:11:22:33:44:55 can never apply.
Stale NetworkAddress=<redacted-mac> cleared from keys 0003/0004 on 2026-06-06.

---

## Operational notes

- SSH-to-Windows from a Mac: nested quoting + cmdline-length limits bite. Deploy scripts
  by base64-over-stdin to a .b64 file, then decode on Windows with [Convert]::FromBase64String.
- Hotspot virtual adapter name increments on each restart (Local Area Connection* N).
- Recreate the virtual adapter only via start-hotspot-now.ps1 - disable/enable destroys it.

## Reboot log
- 2026-06-06 21:15 - reboot test #1: WSL/Docker/zrok auto-recovered; hotspot needed hardened retry (applied after).
- 2026-06-06 21:28 - reboot test #2: ALL auto-recovered (incl hotspot On by itself); MAC stable.


---

## TCP/Hotspot stability fix (2026-06-08)

### Problem
Hotspot was structurally stable (boots reliably since 2026-06-06) but TCP performance
was poor for high-throughput video streaming (TikTok). Symptoms: stalls every 10-30s,
rebuffering, slow recovery.

### Root causes found
1. **MSS fragmentation** - ClampMss was Disabled on both Ethernet 5 (USB modem) and
   the hotspot adapter. TikTok CDN MSS=1460 was hitting USB modem MTU ceiling -> silent
   fragmentation -> stalls.
2. **TCP RWIN over-growth through ICS NAT** - autotuninglevel=normal lets the window
   balloon past what ipnathlp.dll (ICS) tracks cleanly across the NAT boundary.
3. **No pacing / burst flooding** - Pacing was off; bursty CDN downloads flooded the
   USB modem queue -> tail-drop -> retransmits -> stutter.
4. **VirtualBox NDIS6 filter bound to hotspot adapter** - vboxnetflt was intercepting
   every packet on Local Area Connection* 11, blocking RSC and adding per-packet overhead.

### Fixes applied
| Change | Command |
|--------|---------|
| ClampMss on hotspot adapter | Set-NetIPInterface -InterfaceAlias "Local Area Connection* 11" -ClampMss Enabled |
| ClampMss on USB modem | Set-NetIPInterface -InterfaceAlias "Ethernet 5" -ClampMss Enabled |
| TCP auto-tuning restricted | netsh int tcp set global autotuninglevel=restricted |
| ECN enabled | netsh int tcp set global ecncapability=enabled |
| CTCP congestion provider | netsh int tcp set supplemental template=Internet CongestionProvider=CTCP |
| VirtualBox NDIS unbound | Disable-NetAdapterBinding -Name "Local Area Connection* 11" -ComponentID vboxnetflt |

### Persistence
C:\start-hotspot-now.ps1 updated to re-apply ClampMss + vboxnetflt unbind after each
hotspot start (hotspot virtual adapter gets a new name index on each recreation).
Global TCP settings (autotuninglevel, ECN, CTCP) persist in registry - survive reboots.

### Verified live
- autotuninglevel: restricted
- ecncapability: enabled
- ClampMss: Enabled on both adapters
- vboxnetflt: unbound from hotspot adapter


