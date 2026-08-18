# netops-lab

## Goal

Power on a factory-blank MikroTik router, touch nothing, and watch it come up
fully configured via DHCP-based ZTP. After that cycle is reliable, the same
rig is the substrate for a lockout experiment. Can an agent on a live router
avoid locking itself out?

**Write-up:** [Zero-Touch Provisioning](https://sanlee.me/projects/netops-lab.html).

## Hardware

| Device | Role |
|---|---|
| MikroTik hEX refresh, E50UG (RouterOS 7, ARM 32-bit, 512MB RAM, 128MB NAND) | device under test |
| Raspberry Pi 5, 8GB, NVMe boot | ZTP / Netinstall host, then agent host |

The router is the cheap end of MikroTik's lineup. See
[decisions/002](decisions/002-keep-the-hex-decline-rb5009.md).
The Pi hosts containers and the agent. The router does not. See
[decisions/003](decisions/003-on-router-containers.md).

### Bring-up kit

What the Pi build used, recorded after the fact (2026-07-25).

| Item | Role |
|---|---|
| Argon NEO 5 M.2 NVMe case | Enclosure *and* NVMe carrier — replaces a separate M.2 HAT; ships its own PCIe ribbon and screws. Single-sided SSDs only. |
| Ranxiana NVMe SSD, M.2 2280 | Root filesystem — enumerates as `nvme0n1`, 238.5G usable |
| Precision Phillips PH0 | Case and carrier screws (Greenworks 6pc precision set) |
| USB flash drive, 64GB | Install medium, then rescue image — see below |
| Pi 5 PSU, 27W USB-C PD | Power |

**No microSD was involved.** The Pi installed from the USB stick. The stick
stays as a known-good rescue image for this machine.

Read [docs/bring-up-notes.md](docs/bring-up-notes.md) before you cable a host
onto the lab segment. Pin the lab NIC interface metric first. Turn Energy
Efficient Ethernet off on the host NIC.

## Topology

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="images/topology-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="images/topology-light.svg">
    <img alt="Lab topology: San's PC and a Raspberry Pi 5 are dual-homed — Wi-Fi to an untouched home router, Ethernet to a MikroTik hEX on an isolated lab segment — so a lab-segment lockout remains observable over Wi-Fi." src="images/topology-dark.svg" width="720">
  </picture>
</p>

The Pi is dual-homed: one interface on the isolated lab segment, one on the
house wifi. A lockout on the lab segment leaves the wifi session up.

The Pi lands on **ether1**, the port the hEX netinstalls from. That port is
WAN in the stock config. The provisioning script opens management for the Pi
on ether1. See [decisions/005](decisions/005-pi-as-ztp-host.md).

## WireGuard + house uplink

Designed in [decisions/009](decisions/009-wireguard-endpoint-and-uplink.md).
Live on hardware 2026-08-11. The home-LAN path was verified: PC WireGuard,
then `ping 10.99.0.1` and `ping 192.168.88.1`. Field notes:
[2026-08-11](docs/bring-up-notes.md#2026-08-11--wireguard-endpoint-live-house-uplink-on-ether5).

| Piece | Where |
|---|---|
| ether5 house uplink, DHCP client, NAT masquerade, UDP/51820 accept | `provisioning/default-config.rsc` (survives wipe) |
| `wg-lab` tunnel + San peer | `provisioning/apply-wireguard.sh` (keys on Pi only) |
| Auto re-apply after wipe | `reprovision.sh` calls apply when `~/.config/netops-lab/wg-lab.private` exists |

**Placement:** Pi + hEX sit by the house/VZ router (short cables: Pi→ether1,
ether5→VZ LAN). PC stays on house wifi only. Pi SSH user is `sanlee@goguma`.

```bash
# on goguma — keys never in git
mkdir -p ~/.config/netops-lab && chmod 700 ~/.config/netops-lab
# server private → ~/.config/netops-lab/wg-lab.private  (mode 600, full ~44-char key)
# laptop public  → ~/.config/netops-lab/wg-client-san.public  # must match PC client.private
chmod +x ~/netops-lab/provisioning/apply-wireguard.sh
./provisioning/apply-wireguard.sh
# home test Endpoint = <ether5 bound address>:51820  (not hairpin via public IP)
# off-site: VZ UDP 51820 → ether5 address + Endpoint = public IPv4:51820
```

After key changes, confirm alignment before you blame the firewall:

```bash
ssh lab-router '/interface wireguard print proplist=name,public-key,listen-port'
ssh lab-router '/interface wireguard peers print proplist=interface,public-key,allowed-address'
# PC: Get-Content client.private -Raw | & "C:\Program Files\WireGuard\wg.exe" pubkey
```

## Status

Hardware was ordered 2026-07-22 and was in hand 2026-07-25.
On 2026-07-26 a wiped board went from factory-blank to fully configured on
one power cycle.
`netinstall-cli` runs on the Pi under user-mode QEMU and pushes
[provisioning/default-config.rsc](provisioning/default-config.rsc).
A repeat cycle is one command on the Pi,
[provisioning/reprovision.sh](provisioning/reprovision.sh)
([decisions/008](decisions/008-unattended-wipe-cycle.md)).
Host-side SSH on the Pi still needs a human after a reboot
([decisions/006](decisions/006-management-surface-on-ether1.md)).
The field record is [docs/bring-up-notes.md](docs/bring-up-notes.md).

## Roadmap

1. ~~**ZTP + Netinstall.**~~ Done 2026-07-26.
   [decisions/005](decisions/005-pi-as-ztp-host.md),
   [decisions/006](decisions/006-management-surface-on-ether1.md),
   [decisions/008](decisions/008-unattended-wipe-cycle.md).
2. ~~**WireGuard endpoint + house uplink.**~~ Live 2026-08-11.
   [decisions/009](decisions/009-wireguard-endpoint-and-uplink.md).
   Off-site Endpoint (VZ port-forward + public IPv4) still to confirm.
3. FRR / OSPF-BGP on the Pi
4. Netwatch-driven self-lockout experiment
5. Remote syslog off-box (so router logs survive the router going unreachable)

**Backlog (decided, not yet ordered):**

- Certificate authority
- VLAN segmentation
- The Dude monitoring
- Pi hosting `kb-agent` persistently
- k8s as a CNI/BGP networking lab

## Why hardware

This lab uses real hardware so it can witness bare-metal bring-up, out-of-band
recovery, and management-plane behavior that a simulator hides. See
[decisions/001](decisions/001-hardware-substrate-scope.md).

## Bring-up notes

[docs/bring-up-notes.md](docs/bring-up-notes.md) is the field log for
physical bring-up. It records symptoms, what they meant, and what fixed them.

## Decisions

See [decisions/](decisions/) for the ADR log.
