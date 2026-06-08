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
  all the TCP tuning targets (see `windows/setup/tcp-tune.ps1`).

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
- **Real-world throughput over the USB cable to the laptop: ~20–40 Mbps** on a good
  day, bursty and lossy. (The modem's *own* built-in Wi-Fi hotspot is throttled even
  harder by its firmware — **~10 Mbps** — which is why we don't use it; see below.)

Honest spec line:

> **USB 4G LTE Modem — advertised "500Mbps"; actually LTE Cat 4 (≤150 Mbps PHY);
> real-world ~20–40 Mbps over USB / ~10 Mbps on its own Wi-Fi; hard-capped by the
> modem's SoC + RNDIS overhead, not the air interface or the USB bus.**

## Two bottlenecks that happen to match 🎯

There are **two different ceilings** depending on the path, and the nice part is they
line up — so nothing is wasted.

```
Modem LTE (~20-40 Mbps over USB)
   │
   ├─► [USB] ─► Fujitsu laptop (server)        gets the full ~20-40 Mbps, wired
   │
   └─► modem's own Wi-Fi ── ~10 Mbps           (throttled by firmware — UNUSED)

Fujitsu's Intel AC 8265 Wi-Fi, in SoftAP/hotspot mode
   └─► re-broadcasts to phones ── ~12-13 Mbps  (the adapter is the limit here)
```

- **Internet → phone** (modem → laptop USB → laptop hotspot → phone): the ceiling is
  the **laptop's Intel AC 8265 hotspot at ~12-13 Mbps**. The AC 8265 in SoftAP mode is
  mediocre — it shares one radio between client and AP duties — but it's *higher* than
  the modem's own 10 Mbps Wi-Fi, which is exactly why we route through the laptop
  instead of letting phones connect to the modem directly.
- **Phone → Immich upload** (phone → laptop hotspot → local Immich, **never touches the
  modem**): this is pure **local LAN**. ~12-13 Mbps (~1.5 MB/s) is more than enough to
  back up photos and videos over the air to a server one room away. For the actual job
  this box exists to do, the hotspot speed is **already ideal**.

**The realization:** the modem's real output (~20-40 Mbps) and the laptop's hotspot
ceiling (~12-13 Mbps) are **roughly matched** — the Intel AC can't even fully consume
what the modem delivers. So the "slow" modem costs nothing on the phone path, and
buying a faster modem would be pointless: the AC 8265 hotspot would just throttle it
back down anyway. **The two bottlenecks fit each other.**

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
`health-watchdog.ps1` re-clamps the modem every 5 min, and `hotspot-start.ps1`
re-applies the hotspot tuning on each start. The global bits (`autotuning`, `ECN`,
`CTCP`) persist in the registry across reboots.

## Known limitations / upgrade paths

- **Single uplink = single point of failure.** One USB modem is the only path to the
  internet. Resilience upgrades: a modem with an **external antenna port** (better
  signal beats any tuning), or a **second uplink** for failover.
- **The modem SoC is the permanent ceiling.** No amount of tuning lifts real
  throughput past what that chip can push; the tuning only stops it from collapsing
  *below* that ceiling under load.
- **A faster modem would NOT help the phone path.** The laptop's Intel AC 8265 hotspot
  (~12-13 Mbps) is already below the modem's ~20-40 Mbps USB output, so it's the binding
  constraint for phones. Spend money on a **better Wi-Fi adapter / USB Wi-Fi 6 dongle in
  AP mode** before a better modem — *that's* what would raise the phone ceiling. (Local
  Immich uploads are already fine at 12-13 Mbps and don't need it.)
