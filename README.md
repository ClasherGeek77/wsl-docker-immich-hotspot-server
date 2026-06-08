# home-server-repro

Reproducible setup for a Windows 10 IoT box running a **WSL2 + Docker** home server
(Immich photo server) exposed publicly via **zrok**, reachable over **Tailscale**,
and acting as a **Wi-Fi hotspot** off a USB LTE modem — with all the boot-reliability
and TCP-stability fixes that make it survive reboots unattended.

> Host of record: `<hostname>` (Windows 10 IoT Enterprise LTSC, build 19044).
> SSH alias `pc-remote`. This repo lets you rebuild it from scratch.

## What's in the box

| Layer | What it is |
|-------|-----------|
| **WSL2** (Ubuntu-22.04) | Linux runtime hosting Docker |
| **Docker** | systemd-managed; `docker.service` enabled |
| **Immich** | self-hosted photos — `immich/docker-compose.yml` |
| **zrok** | public HTTPS tunnel to Immich (`https://<share>.share.zrok.io`) |
| **Tailscale** | private mesh access to the box |
| **Hotspot** | Wi-Fi Direct SoftAP + Windows ICS, upstream = USB LTE modem |

## Repo layout

```
immich/
  docker-compose.yml        # Immich + Postgres + Redis + ML + zrok (verbatim)
  .env.example              # copy to .env, fill secrets (gitignored)
windows/
  scripts/
    wsl-up.ps1              # boots WSL, ensures Docker, BLOCKS as keepalive anchor
    wsl-health.ps1          # 5-min self-heal; also re-applies modem ClampMss
    start-hotspot-now.ps1   # hardened hotspot start + re-applies hotspot TCP tuning
    tcp-tune-hotspot.ps1    # standalone TCP/QoS tuning (one-shot apply)
    rebuild_tasks.ps1       # (re)create AutoStartWSL + WSLDockerHealth scheduled tasks
    fix_health.ps1          # repair WSLDockerHealth trigger
    fix-wsl-final.ps1       # historical: Run-key based WSL autostart attempt
docs/
  server-journal.md         # running journal of state, tasks, root-causes, fixes
  FIXES_APPLIED.md          # detailed boot-reliability root-cause writeup
```

## The core problem this solves

**WSL tears down its VM when no Linux session is attached** → kills `dockerd` → kills
all containers → zrok returns **502**. SYSTEM-context WSL is blocked by WSL itself
(`WSL_E_LOCAL_SYSTEM_NOT_SUPPORTED`), and interactive-logon tasks don't fire on a
headless boot. The fix is a **keepalive anchor**: a foreground `wsl … sleep` loop
(`wsl-up.ps1`) run by a scheduled task as the user (LogonType=Password, "run whether
logged on or not"), which holds the WSL VM open forever. A 5-min health task
(`wsl-health.ps1`) is the belt-and-suspenders layer.

See `docs/FIXES_APPLIED.md` and `docs/server-journal.md` for the full forensic trail.

## Bring-up from scratch

### 1. Windows prerequisites
- Enable WSL2 + install `Ubuntu-22.04`
- Inside WSL: install Docker, `systemctl enable docker`
- Install Tailscale (Windows), join your tailnet
- USB LTE modem plugged in (shows as **Remote NDIS** adapter)

### 2. Immich + zrok
```bash
cd immich
cp .env.example .env        # then edit .env with real secrets
docker compose up -d
```
`ZROK_ENABLE_TOKEN` comes from your zrok account; `ZROK_SHARE_NAME` is your public
subdomain. The compose runs zrok in `share reserved … --headless` mode against
`immich-server:2283`.

### 3. Scheduled tasks (boot reliability)
Copy `windows/scripts/*.ps1` to `C:\`, then from an elevated PowerShell:
```powershell
powershell -ExecutionPolicy Bypass -File C:\rebuild_tasks.ps1
```
This registers:
- **AutoStartWSL** — AtStartup + AtLogon → `wsl-up.ps1` (keepalive anchor, RestartCount 999)
- **WSLDockerHealth** — every 5 min → `wsl-health.ps1`

### 4. Hotspot
```powershell
powershell -ExecutionPolicy Bypass -File C:\start-hotspot-now.ps1
```
Hardened: waits up to ~90s for the modem's InternetAccess profile, then
Start + verify + retry until tethering is On. SSID/passphrase are set inside the script.

### 5. TCP stability tuning (streaming over the hotspot)
```powershell
powershell -ExecutionPolicy Bypass -File C:\tcp-tune-hotspot.ps1
```
Stabilises TikTok scrolling / WhatsApp calls over the ICS+USB-modem path. Global bits
persist in the registry; per-adapter bits are re-applied automatically by
`start-hotspot-now.ps1` (hotspot) and `wsl-health.ps1` (modem). See the journal entry
"TCP/Hotspot stability fix" for the root-cause analysis.

## Secrets

Nothing secret is committed. All sensitive values live in `immich/.env`
(gitignored); the template is `immich/.env.example`. zrok/ziti identity files
(`.zrok/`, `.zrok2/`) are gitignored too.

## Verifying it's healthy
```powershell
# Tasks running
Get-ScheduledTask | ? { $_.TaskName -match 'WSL|Hotspot|Docker' } | ft TaskName,State
# Docker up inside WSL
wsl -d Ubuntu-22.04 -u root -- systemctl is-active docker
# Public tunnel
curl -I https://<your-share>.share.zrok.io      # expect HTTP 200
# TCP tuning landed
netsh int tcp show global | findstr /i "auto-tuning ecn"
```
