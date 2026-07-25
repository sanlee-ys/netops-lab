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
| MikroTik hEX (RouterOS, MMIPS) | device under test |
| Raspberry Pi 5, 8GB, NVMe boot | agent host |

The router is deliberately the cheap end of MikroTik's lineup — see
[decisions/002](decisions/002-keep-the-hex-decline-rb5009.md) for why a
pricier router was considered and declined. It's also container-incapable by
design (MMIPS, 16MB flash); all container workloads (FRR, syslog viewer,
future agent runtime) live on the Pi, never the router.

### Bring-up kit

What the Pi build actually used, recorded after the fact (2026-07-25).

| Item | Role |
|---|---|
| Argon NEO 5 M.2 NVMe case | Enclosure *and* NVMe carrier — replaces a separate M.2 HAT; ships its own PCIe ribbon and screws. Single-sided SSDs only. |
| Ranxiana NVMe SSD, M.2 2280 | Root filesystem — enumerates as `nvme0n1`, 238.5G usable |
| Precision Phillips PH0 | Case and carrier screws (Greenworks 6pc precision set) |
| USB flash drive, 64GB | Install medium, then rescue image — see below |
| Pi 5 PSU, 27W USB-C PD | Power |

**No microSD was needed.** The Pi booted from the USB stick, the EEPROM was
updated from that running system, and `rpi-clone` copied it to the NVMe. The
stick is kept as a known-good rescue image for this machine — worth more here
than a spare drive, in a lab whose premise is out-of-band recovery.

Two things that would have cost an evening if hit blind:

- **The factory EEPROM was a year stale** (June 2025 against a May 2026
  release) and predates working NVMe boot. Update it *before* imaging the
  drive, so a boot failure has one possible cause instead of two.
- **Use the maintained `rpi-clone` fork.** The original writes a wrong path
  into `cmdline.txt` on Pi 5 and the clone won't boot; the fork fixes the
  `cmdline.txt` and `/etc/fstab` PARTUUID rewrites, which is the whole
  fiddly part of cloning.

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
    PI["Raspberry Pi 5<br/>(agent host)"] -- ethernet --> HEX
    PI -- wifi --> HR
```

The Pi is deliberately dual-homed: one interface on the isolated lab segment,
one on the house wifi. When an agent severs the Pi's lab-segment link, the
wifi session survives — so the lockout is observable from inside the agent's
own host, instead of requiring physical access to recover.

## Why hardware, not a simulator

Tools like containerlab are free and better for topology *volume*. This lab
is about *fidelity*: bare-metal bring-up, out-of-band recovery, and
management-plane behavior that a simulator abstracts away — exactly the
parts that are hardest to get right without hands-on practice. See
[decisions/001](decisions/001-hardware-substrate-scope.md).

## Roadmap

Sequenced, not exhaustive — this is what's ordered so far. Backlog below is
real but unscheduled.

1. **ZTP + Netinstall closure** — first deliverable, gates everything below
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

Hardware ordered 2026-07-22, received 2026-07-25.

**Pi bring-up complete** (2026-07-25). `goguma` boots from NVMe, runs headless
on wifi, EEPROM current. That closes the substrate gate on everything below.

The hEX is still boxed. Roadmap item 1 — ZTP + Netinstall closure — is next,
and it starts with design decisions about the provisioning path, not a build
checklist.

## Decisions

See [decisions/](decisions/) for the ADR log.
