# wsl-docker-immich-hotspot-server

A Windows laptop that is **both a self-hosted photo server and a portable Wi-Fi
router** — WSL2 + Docker running [Immich](https://immich.app), exposed publicly via
[zrok](https://zrok.io), reachable over [Tailscale](https://tailscale.com), sharing a
USB-LTE uplink as a Wi-Fi hotspot — with all the boot-reliability and TCP-stability
fixes that let it survive reboots completely unattended.

Runs on a **~$189 setup** (used Fujitsu Lifebook U938 + an $8 USB LTE modem).
See **[docs/hardware.md](docs/hardware.md)** for the bill of materials and why a cheap
modem needs a software TCP trick.

---

## ⚡ Quick start (one command)

From an **elevated PowerShell**, at the repo root:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

That's it. The installer is interactive and safe to re-run — it checks prerequisites,
stages the scripts to `C:\home-server\`, prompts for your secrets (writes a gitignored
`immich/.env`), registers the scheduled tasks, brings up the Docker stack, starts the
hotspot, applies the TCP tuning, and prints a health summary.

> Prereqs it expects: WSL2 with `Ubuntu-22.04`, Docker installed inside WSL
> (`systemctl enable docker`), Tailscale joined, and the USB LTE modem plugged in.

---

## 🗺️ Architecture

```
 Phone (TikTok / WhatsApp / Immich app)
    │  Wi-Fi
    ▼
 ┌─────────────────────── Fujitsu Lifebook U938 ───────────────────────┐
 │  Wi-Fi Direct hotspot  ──►  Windows ICS (NAT)                        │
 │                                   │                                  │
 │  WSL2 (Ubuntu-22.04)              │ USB                              │
 │   └─ Docker ─ Immich + Postgres + Redis + ML + zrok                  │
 │        │                          ▼                                  │
 │        │                  USB 4G LTE modem (Remote NDIS)             │
 │   Tailscale (mesh)                │  LTE                             │
 └────────│──────────────────────────│──────────────────────────────────┘
          ▼                          ▼
   private mesh access        Internet ──► zrok public HTTPS tunnel
```

The single hard problem this repo solves: **WSL tears down its VM when no Linux session
is attached → kills `dockerd` → zrok returns 502.** The fix is a *keepalive anchor* —
a foreground `wsl … sleep` loop held open by a scheduled task. Full forensic detail in
**[docs/journal/](docs/journal/)**.

---

## 📂 Repo layout

```
install.ps1                  ⭐ one-click installer (stages to C:\home-server\)
immich/
  docker-compose.yml         Immich + Postgres + Redis + ML + zrok
  .env.example               copy to .env, fill secrets (gitignored)
windows/                     Windows-side, split by ROLE
  runtime/                   scripts the system runs ITSELF
    keepalive-anchor.ps1       holds the WSL VM open (task: AutoStartWSL)
    health-watchdog.ps1        5-min self-heal (task: WSLDockerHealth)
    hotspot-start.ps1          hotspot bring-up + verify/retry
  setup/                     scripts run ONCE at install time
    register-tasks.ps1         (re)register the scheduled tasks
    tcp-tune.ps1               global + per-adapter TCP/QoS tuning
  lib/
    network-tuning.ps1         shared ClampMss / vboxnetflt / global-TCP helpers
  README.md                  expert deep-dive: each script + when it fires
docs/
  hardware.md                bill of materials + the cheap-TCP-trick rationale
  journal/                   dated forensic log (history, not spec)
    FIXES_APPLIED.md
    server-journal.md
```

The **`runtime/` vs `setup/`** split is the thing to internalize: `runtime/` scripts are
invoked by Windows on a schedule or forever; `setup/` scripts you (or `install.ps1`) run
once. See **[windows/README.md](windows/README.md)** for the per-script deep-dive.

---

## 🔧 Manual operation (if you skip the installer)

```powershell
# 1. Secrets
cp immich\.env.example immich\.env   # then edit with real values

# 2. Stage scripts (installer normally does this) to C:\home-server\{runtime,setup,lib}

# 3. Register tasks (point them at the staged runtime dir)
windows\setup\register-tasks.ps1 -RuntimeDir C:\home-server\runtime

# 4. Immich + zrok
wsl -d Ubuntu-22.04 -u root -- bash -c "cd /mnt/d/home-server/immich && docker compose up -d"

# 5. Hotspot + TCP tuning
C:\home-server\runtime\hotspot-start.ps1
C:\home-server\setup\tcp-tune.ps1
```

## ✅ Health check

```powershell
Get-ScheduledTask | ? { $_.TaskName -match 'WSL|Hotspot|Docker' } | ft TaskName,State
wsl -d Ubuntu-22.04 -u root -- systemctl is-active docker
curl -I https://<your-share>.share.zrok.io      # expect HTTP 200
netsh int tcp show global | findstr /i "auto-tuning ecn"
```

## 🔒 Secrets

Nothing secret is committed. Real values live in `immich/.env` (gitignored); the
template is `immich/.env.example`. The hotspot passphrase and zrok token are read from
that env file — never hardcode them. zrok/ziti identity (`.zrok/`, `.zrok2/`) is
gitignored too.
