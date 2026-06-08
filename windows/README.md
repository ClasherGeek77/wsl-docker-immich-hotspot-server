# windows/ — Windows-side orchestration

These scripts make a Windows laptop behave like an always-on appliance. They're split
by **role** so it's obvious which run themselves and which you run once.

The installer stages this folder to `C:\home-server\` preserving the structure
(`runtime\`, `setup\`, `lib\`), because the scripts dot-source `..\lib\network-tuning.ps1`
relative to their own location — so `runtime\` and `setup\` must keep `lib\` as a sibling.

## `runtime/` — the system runs these itself

| Script | Invoked by | What it does |
|--------|-----------|--------------|
| **keepalive-anchor.ps1** | Task `AutoStartWSL` (AtStartup + AtLogon, RestartCount 999) | Boots WSL, ensures Docker (systemd, falls back to direct `dockerd`), then **blocks forever** in a foreground `wsl … sleep 60` loop. That foreground process is what holds the WSL VM open — the entire fix for the zrok-502 idle-out. |
| **health-watchdog.ps1** | Task `WSLDockerHealth` (every 5 min) | Belt-and-suspenders: ensures `AutoStartWSL` is Running, best-effort restarts Docker, and re-applies the USB-modem `ClampMss` (runtime-only, resets on reboot). |
| **hotspot-start.ps1** | Task at boot / `install.ps1` | Waits up to ~90s for the modem's InternetAccess profile, configures SSID/passphrase from `$env:HOTSPOT_SSID`/`$env:HOTSPOT_PASSPHRASE`, then Start + verify + retry (≤5×) until tethering is On. On success, re-applies the hotspot TCP tuning. |

## `setup/` — run once at install

| Script | What it does |
|--------|--------------|
| **register-tasks.ps1** | (Re)registers `AutoStartWSL` + `WSLDockerHealth`. Parameterized: `-RuntimeDir` (where the runtime scripts live) and `-HostUser` (the account the tasks run as). Idempotent. |
| **tcp-tune.ps1** | One-shot: applies the global netsh TCP settings (registry-backed, survive reboot) + per-adapter `ClampMss`/`vboxnetflt` via the shared lib. |

## `lib/` — shared, dot-sourced

| File | Provides |
|------|----------|
| **network-tuning.ps1** | `Set-ModemClampMss`, `Set-HotspotTcpTuning`, `Set-GlobalTcpTuning` — the single source of the TCP/QoS logic, so the three callers above don't copy-paste it. |

## Why the TCP tuning exists

The cheap USB modem fragments large packets, and Windows ICS is a toy NAT — so
high-throughput streaming (TikTok, WhatsApp calls) stalls without help. The fix is
`ClampMss` + `restricted` autotuning + `CTCP` + `ECN`, plus unbinding a stray VirtualBox
NDIS filter. Full root-cause: [../docs/journal/server-journal.md](../docs/journal/server-journal.md)
("TCP/Hotspot stability fix") and [../docs/hardware.md](../docs/hardware.md).
