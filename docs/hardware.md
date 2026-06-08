# Hardware — Bill of Materials & Rationale

What this home server actually runs on, what it cost, and why a pile of cheap
parts needs a software layer to behave like real networking gear.

## Bill of Materials

| Component | Model | Price (IDR) | Price (USD)¹ |
|-----------|-------|------------:|-------------:|
| Server / host | **Fujitsu Lifebook U938** — Intel Core i5/i7 **Gen 8**, 13.3" ultraslim, ~20GB RAM, 256–512GB SSD | Rp 2,940,000 | ~$181 |
| Internet uplink | **USB 4G LTE Modem** (RNDIS, "All Operator", advertised "500Mbps") | Rp 134,499 | ~$8 |
| | **Total** | **Rp 3,074,499** | **≈ $189** |

¹ At ~Rp 16,200/USD (mid-2026). The rupiah floats, so treat USD as approximate.

A complete, always-on, publicly-reachable photo server **and** a portable Wi-Fi
router — for **under $190**, on a used business ultrabook and the cheapest LTE
dongle on the marketplace.

## Roles in the topology

The laptop is **both the server and the router**.

```
Phone (TikTok / WhatsApp call)
   │  Wi-Fi
   ▼
Fujitsu U938 ── Wi-Fi Direct hotspot (laptop broadcasts the SSID)
   │           └─ Windows ICS (NAT via ipnathlp.dll)
   │  USB
   ▼
USB 4G LTE Modem ── shows up as "Remote NDIS" adapter (Ethernet 5)
   │  LTE
   ▼
Internet ──► Immich exposed via zrok · box reachable via Tailscale
```

- **Fujitsu U938** — runs Windows 10 IoT LTSC + WSL2 + Docker (Immich's 8-container
  stack), and simultaneously broadcasts the Wi-Fi hotspot. Gen-8 i5 is ample; the
  thing that matters is **RAM** (prefer the 20GB variant — Immich's ML container is
  hungry during indexing) and that **photo storage lives on the D: drive**
  (`/mnt/d/home-server/photos`), not the system SSD.
- **USB LTE modem** — the upstream internet. It is the `Remote NDIS` interface that
  all the TCP tuning targets (see `windows/scripts/tcp-tune-hotspot.ps1`).

## About that "500Mbps" 🙄

The box says **500Mbps**. That is marketing fiction.

- It's **LTE Cat 4 at most**: 150 Mbps down / 50 Mbps up — and that's the *theoretical
  PHY ceiling* (20MHz, 2×2 MIMO, sitting on top of the tower).
- **The real cap isn't the radio — it's the modem's brain.** These no-name dongles
  run an ancient Qualcomm MDM9x07-class (or Hisilicon Balong) SoC that does the LTE
  stack, NAT, *and* RNDIS encapsulation on one tiny underpowered core. That core
  saturates long before the air interface or USB bus does.
- **RNDIS is a tax**: every frame is wrapped for USB transport with no offload, packet
  by packet, on that weak chip. Buffers are shallow and dumb.
- **Real-world throughput: ~20–40 Mbps on a good day**, with bursty, lossy behavior.

Honest spec line:

> **USB 4G LTE Modem — advertised "500Mbps"; actually LTE Cat 4 (≤150 Mbps PHY);
> real-world ~20–40 Mbps; hard-capped by the modem's SoC + RNDIS overhead, not the
> air interface or the USB bus.**

## Why the "cheap TCP/IP trick" exists

We built a router out of parts that were never meant to be one, and saved money doing
it. You **cannot** make the modem's SoC faster — you can only stop feeding it traffic
in a way that makes it choke. That is the entire job of the TCP tuning
(`docs/server-journal.md` → "TCP/Hotspot stability fix"):

| Symptom (caused by the cheap modem) | Software fix | What it does |
|---|---|---|
| MSS 1460 packets fragment at the modem's sub-1500 MTU → stalls | **`ClampMss`** on modem + hotspot | force smaller packets so nothing fragments |
| TCP receive window over-grows past what ICS's toy NAT can track → bufferbloat | **`autotuninglevel=restricted`** | adapt, but stay inside what ICS handles |
| Bursty CDN downloads overflow the modem's shallow queue → tail-drop → stutter | **CTCP** congestion provider | pacing tuned for high-latency/variable LTE |
| Hard drops instead of graceful backoff on a WhatsApp call | **ECN** enabled | signal congestion *before* the queue overflows |
| Stray VirtualBox NDIS filter in the hotspot packet path | **unbind `vboxnetflt`** | free latency / unblock offload |

**The philosophy:** instead of a $100+ proper LTE router with a competent SoC and real
AQM, we spent **$8 on a dumb modem** and made up the difference with a handful of free
`netsh` / `Set-NetIPInterface` commands. We don't make the modem faster — we make the
**traffic gentle enough that the modem's brain doesn't fall over**. The cost moved from
hardware to config.

Because those per-adapter settings are runtime-only, they're re-applied automatically:
`wsl-health.ps1` re-clamps the modem every 5 min, and `start-hotspot-now.ps1`
re-applies the hotspot tuning on each start. The global bits (`autotuning`, `ECN`,
`CTCP`) persist in the registry across reboots.

## Known limitations / upgrade paths

- **Single uplink = single point of failure.** One USB modem is the only path to the
  internet. Resilience upgrades: a modem with an **external antenna port** (better
  signal beats any tuning), or a **second uplink** for failover.
- **The modem SoC is the permanent ceiling.** No amount of tuning lifts real
  throughput past what that chip can push; the tuning only stops it from collapsing
  *below* that ceiling under load.
