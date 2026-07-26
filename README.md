# netops-lab

A personal MikroTik + Raspberry Pi home lab. The driving goal: get real,
hands-on zero-touch provisioning (ZTP) experience on hardware I own. Once
ZTP is proven, the same rig becomes the substrate for a second experiment —
can an agent operating on a live router avoid locking itself out.

## Goal

Power on a factory-blank MikroTik router, touch nothing, and watch it come up
fully configured — via DHCP-based ZTP. That sequencing is deliberate: a
reliable wipe-to-provisioned cycle is the experimental harness that makes the
later agent experiment repeatable. Without it, every lockout is a manual
rebuild.

## Hardware

| Device | Role |
|---|---|
| MikroTik hEX refresh, E50UG (RouterOS 7, ARM 32-bit, 512MB RAM, 128MB NAND) | device under test |
| Raspberry Pi 5, 8GB, NVMe boot | ZTP / Netinstall host, then agent host |

The router is deliberately the cheap end of MikroTik's lineup — see
[decisions/002](decisions/002-keep-the-hex-decline-rb5009.md) for why a
pricier router was considered and declined. It *can* run RouterOS containers
(ARM, though only 128MB of NAND), but all container workloads — FRR, syslog
viewer, future agent runtime — live on the Pi by design, never the router:
the Pi is the dual-homed agent host, and hosting the agent on the device it
might sever would defeat the lockout observation. See
[decisions/003](decisions/003-on-router-containers.md).

### Bring-up kit

What the Pi build actually used, recorded after the fact (2026-07-25).

| Item | Role |
|---|---|
| Argon NEO 5 M.2 NVMe case | Enclosure *and* NVMe carrier — replaces a separate M.2 HAT; ships its own PCIe ribbon and screws. Single-sided SSDs only. |
| Ranxiana NVMe SSD, M.2 2280 | Root filesystem — enumerates as `nvme0n1`, 238.5G usable |
| Precision Phillips PH0 | Case and carrier screws (Greenworks 6pc precision set) |
| USB flash drive, 64GB | Install medium, then rescue image — see below |
| Pi 5 PSU, 27W USB-C PD | Power |

**No microSD was involved.** The Pi installed from the USB stick, which is
kept afterward as a known-good rescue image for this machine — worth more
here than a spare drive, in a lab whose premise is out-of-band recovery.

How the bring-up actually went, including the two things that would have cost
an evening if hit blind, is logged in
[docs/bring-up-notes.md](docs/bring-up-notes.md).

## Topology

```mermaid
graph TB
    subgraph home["Home network — never touched by this lab"]
        HR["Home Wi-Fi router"]
    end

    subgraph lab["Isolated lab segment"]
        HEX["MikroTik hEX<br/>(device under test)"]
    end

    PC["San's PC"] -- ethernet --> HEX
    PC -- wifi --> HR
    PI["Raspberry Pi 5<br/>(ZTP host, then agent host)"] -- ethernet to ether1 --> HEX
    PI -- wifi --> HR
```

The Pi is deliberately dual-homed: one interface on the isolated lab segment,
one on the house wifi. When an agent severs the Pi's lab-segment link, the
wifi session survives — so the lockout is observable from inside the agent's
own host, instead of requiring physical access to recover.

The Pi's single NIC lands on **ether1** because that's the port the hEX
netinstalls from — which puts the Pi on what the stock configuration treats
as the WAN side, behind a firewall that drops input from WAN. Opening
management for the Pi on ether1 is therefore part of the provisioning script
itself, and the same surface the lockout experiment later attacks. See
[decisions/005](decisions/005-pi-as-ztp-host.md).

## Why hardware, not a simulator

Tools like containerlab are free and better for topology *volume*. This lab
is about *fidelity*: bare-metal bring-up, out-of-band recovery, and
management-plane behavior that a simulator abstracts away — exactly the
parts that are hardest to get right without hands-on practice. See
[decisions/001](decisions/001-hardware-substrate-scope.md).

## Roadmap

Sequenced, not exhaustive — this is what's ordered so far. Backlog below is
real but unscheduled.

1. ~~**ZTP + Netinstall closure**~~ — **working, 2026-07-26.** Netinstall-driven,
   hosted on the Pi, with the provisioning script arming the next cycle so
   wipes stay repeatable —
   [decisions/005](decisions/005-pi-as-ztp-host.md),
   [decisions/006](decisions/006-management-surface-on-ether1.md)
2. WireGuard endpoint (RouterOS 7 native — pays back every day this lab
   isn't physically reachable)
3. FRR / OSPF-BGP on the Pi
4. Netwatch-driven self-lockout experiment
5. Remote syslog off-box (so router logs survive the router going unreachable)

**Backlog (decided as real additions, not yet ordered):**
- Certificate authority — hands-on version of the RFC 8572 / BRSKI trust
  model this lab's ZTP work is grounded in
- VLAN segmentation
- The Dude monitoring
- Pi hosting `kb-agent` persistently
- k8s as a CNI/BGP networking lab (pod routing, network policy, Calico
  peering with the hEX) — the one k8s scenario judged not to be ceremony;
  parked pending a clear multi-node need, since the cheap path there is
  VMs/kind on the desktop, not more physical hardware

The failure mode to watch for: a beautifully configured router and no ZTP
writeup. Everything below item 1 waits until item 1 actually ships.

## Status

Hardware ordered 2026-07-22, all in hand 2026-07-25.

Two bring-up sessions that day. The PC is on the router's segment, and the Pi
(`goguma`) is built — booting from NVMe, headless on wifi, EEPROM current.
That closes the hardware substrate gate on everything below.

**Roadmap item 1 works.** On 2026-07-26 a wiped board went from
factory-blank to fully configured on **one power cycle** — no button hold, no
console, no serial adapter. `netinstall-cli` runs on the Pi under user-mode
QEMU, serving BOOTP and TFTP on the lab link and pushing
[provisioning/default-config.rsc](provisioning/default-config.rsc), whose
management surface is decided in
[decisions/006](decisions/006-management-surface-on-ether1.md). The Pi then
authenticates to the provisioned router by SSH key, through the single
firewall exception the script wrote for it.

A repeat cycle is one command on the Pi followed by a power cycle —
[provisioning/reprovision.sh](provisioning/reprovision.sh) — and
`ssh lab-router "/system resource print"` then answers with no prompt of any
kind. RouterOS does demand an interactive password change on first login, but
it is interactive-only and a non-interactive session never meets it.

What that cost, and it is worth knowing before repeating this: the barriers to
running unattended were not on the router at all. They were SSH host-key
verification and a key passphrase **on the Pi**, invisible until something
non-interactive tried to run. Zero-touch moved to the host driving it rather
than being achieved outright, and the Pi's `ssh-agent` still needs a human
after a reboot — a limitation that lands on item 4 and is recorded in
[decisions/006](decisions/006-management-surface-on-ether1.md).

One thing remains genuinely unresolved: whether the script's arming line ran,
or whether `boot-device` merely persisted through the format on its own. This
board is armed either way; a *factory* board might not be. The full run,
including the failures along the way, is in
[docs/bring-up-notes.md](docs/bring-up-notes.md).

## Bring-up notes

[docs/bring-up-notes.md](docs/bring-up-notes.md) is the troubleshooting log
for physical bring-up — symptoms, what they meant, and what fixed them. It
already carries two things worth reading *before* cabling a machine onto the
lab segment: pinning the lab NIC's interface metric so the lab router can't
steal the default route, and disabling Energy Efficient Ethernet on the host
NIC, which is what kept the first PC ↔ hEX link from coming up at all.

## Decisions

See [decisions/](decisions/) for the ADR log.
