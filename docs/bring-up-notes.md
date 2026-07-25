# Bring-up notes

Field notes from physically bringing this lab's hardware up: what broke, what
the symptom actually meant, and what fixed it. Troubleshooting and runbook
material only — decisions live in [decisions/](../decisions/), and nothing
here is an ADR.

Entries are newest-first and dated. Host-side commands are PowerShell on
San's PC (Windows 11); anything that changes adapter or interface settings
needs an **elevated** shell.

---

## Quick checklist — Pi won't see or boot the NVMe

1. Does `lsblk` list `nvme0n1` at all? No → reseat the PCIe ribbon at **both**
   ends before suspecting the drive. See
   [drive not detected](#if-the-drive-doesnt-appear-suspect-the-ribbon-first).
2. Drive visible but won't boot from it? Check the EEPROM date first — a
   factory bootloader can predate working NVMe boot. See
   [mandatory pre-step](#mandatory-pre-step-update-the-eeprom-before-imaging-the-nvme).
3. Cloned drive boots to a kernel panic or initramfs prompt? Wrong PARTUUID
   in `cmdline.txt`. See
   [clone with the maintained fork](#clone-with-the-maintained-rpi-clone-fork-not-the-original).

---

## Quick checklist — lab link won't come up

1. Did you pin the lab NIC's interface metric *before* cabling? See
   [mandatory pre-step](#mandatory-pre-step-pin-the-lab-nics-interface-metric).
2. Is the router-side port LED lit while Windows says `Disconnected`? That's
   a one-sided link — suspect the **host** NIC, not the router. See
   [the LED tell](#the-diagnostic-that-split-it-a-lit-router-led-with-a-dead-host-link).
3. First thing to try: turn **Energy Efficient Ethernet** off on the host
   NIC. It is the known-good fix here and is the most likely thing to come
   back, since a driver update can reset adapter defaults. See
   [root cause](#root-cause-energy-efficient-ethernet-8023az).

---

## 2026-07-25 — Pi 5 NVMe bring-up

**Hardware:** Raspberry Pi 5 8GB (`goguma`) in an Argon NEO 5 M.2 NVMe case,
Ranxiana NVMe SSD M.2 2280 (238.5G usable). Brought up **headless** — no
monitor, no keyboard, no microSD at any point; wifi and SSH were preset with
Raspberry Pi Imager and the install ran from a USB stick.

### No microSD is required

The common instruction is "boot from SD, then move to NVMe." A USB stick works
in that role and is the better choice here: flash Raspberry Pi OS Lite to it,
boot the Pi from it, update the EEPROM from that running system, then clone to
the NVMe. The stick then becomes a known-good rescue image for the machine
rather than a card that gets wiped and forgotten.

Set **hostname, username/password, wifi, and SSH in Imager before writing.**
In Imager's customization these live on two different tabs — hostname,
username/password and wifi on **General**, SSH on **Services** — and enabling
SSH without setting a username produces an image with no account on it, which
cannot be logged into headlessly at all. That mistake costs a re-flash.

### Argon NEO 5: the case is the carrier

There is no separate M.2 HAT and no Active Cooler in this build — the case is
the enclosure *and* the NVMe carrier, and it ships its own PCIe ribbon and
screws. Two constraints that are easy to miss:

- **Single-sided SSDs only.** 2280 length fits; NAND on both faces does not.
- **Ribbon orientation is not symmetric** — copper contacts face **up** on the
  carrier-board end. Backwards means the drive simply doesn't enumerate, which
  is indistinguishable from a dead drive.

Assemble and **power on before driving the case screws.** The screws are the
last step in Argon's own instructions, so verifying `lsblk` first costs
nothing and saves a full teardown if the ribbon is wrong.

### If the drive doesn't appear, suspect the ribbon first

```bash
lsblk
ls -l /dev/nvme* 2>/dev/null || echo "no nvme device"
```

A healthy result lists `nvme0n1` as a disk. Absent means reseat the ribbon at
both ends — that is the cause the large majority of the time, ahead of the
drive itself.

### Mandatory pre-step: update the EEPROM before imaging the NVMe

This Pi shipped with a **June 2025** bootloader against a **May 2026** release.
An EEPROM that old can predate working NVMe boot entirely, so a drive that
enumerates fine under Linux still won't boot.

Do this *before* writing anything to the NVMe. Otherwise a boot failure has two
candidate causes — bad clone or incapable bootloader — instead of one.

```bash
sudo rpi-eeprom-update          # check
sudo rpi-eeprom-update -a       # stage the update
sudo reboot
```

`WARNING: SPI device /dev/spidev10.0 not found` during the update is **not** a
fault. It means the EEPROM can't be flashed live, so the tool falls back to
staging `pieeprom.upd` + `recovery.bin` in `/boot/firmware` and applying them at
next boot. That is the normal path. Expect a **double boot** — the recovery
image flashes, then the Pi reboots again — so allow longer than usual before
SSH comes back.

Verify:

```bash
sudo rpi-eeprom-update          # want CURRENT == LATEST
vcgencmd bootloader_version
```

Do not interrupt power during an EEPROM write. This is firmware on the Pi
itself, not data on a disk.

### Clone with the maintained `rpi-clone` fork, not the original

The original (`billw2`) writes a wrong path into `cmdline.txt` on Pi 5 and the
cloned drive won't boot. The maintained fork
([geerlingguy/rpi-clone](https://github.com/geerlingguy/rpi-clone)) fixes it.

```bash
curl -fsSL https://raw.githubusercontent.com/geerlingguy/rpi-clone/master/install -o /tmp/rpi-clone-install
less /tmp/rpi-clone-install      # read it before sudo
sudo bash /tmp/rpi-clone-install
sudo rpi-clone nvme0n1
```

It clones the **currently booted** disk to the target. Give the destination a
distinct filesystem label (`goguma-nvme`) — post-clone both disks are byte-identical
including the source's `rootfs` label, and two identically-labelled filesystems on
one machine is exactly the ambiguity you don't want if anything ever mounts by label.

The two lines that confirm it did the load-bearing work:

```
Editing /mnt/clone/boot/firmware/cmdline.txt PARTUUID to use <id>
Editing /mnt/clone/etc/fstab PARTUUID to use <id>
```

That pair — plus "Changing destination Disk ID", which stops the two disks
colliding on PARTUUID — is the entire fiddly part of cloning a Pi, and the
exact thing a hand-rolled `rsync` clone gets wrong.

**Do not remove the USB stick while this runs.** It is both the running root
filesystem and the source of the copy.

### Not a fault: "unrecognised disk label"

`rpi-clone` opens with `Error: /dev/nvme0n1: unrecognised disk label` against a
blank drive. That is `parted` reporting no partition table yet — expected on a
virgin disk, not something to act on. Recorded here so it isn't chased as a
cause later.

### Finish: boot order, then verify

`sudo raspi-config` → **Advanced Options** → **Boot Order** → **NVMe/USB Boot**.
Then `sudo shutdown -h now`, wait for solid red (halted — the Pi 5 sits in
standby rather than powering fully off), pull the USB stick, and press the
power button.

```bash
findmnt /        # want /dev/nvme0n1p2
lsblk            # want no sda at all
```

Elapsed, for calibration: clone of a 6.7G-used system took **2m12s** over PCIe.

---

## 2026-07-25 — first PC ↔ hEX link

**Hardware:** San's PC (ASUS ROG Maximus IX Formula, onboard Intel I219-V,
`ifIndex 10`, adapter name `Ethernet`) ↔ MikroTik hEX refresh (E50UG),
router port `ether2`.

`ifIndex 10` and the name `Ethernet` are specific to this machine. Confirm
before reusing any command below:

```powershell
Get-NetAdapter | Format-Table Name, InterfaceIndex, Status, LinkSpeed
```

### Mandatory pre-step: pin the lab NIC's interface metric

Do this **before** plugging into the lab segment, on any machine being
dual-homed onto it.

Windows assigns route metrics automatically, and it had ranked the wired lab
NIC at **5** against Wi-Fi at **30** — i.e. the lab NIC was strongly
preferred for the default route. The hEX **did** advertise itself as a
default gateway when the DHCP lease completed. This was a real hit, not a
hypothetical: without the pin, the PC's entire default route would have moved
to a router whose WAN port is unplugged, and internet access would have
dropped the moment the link came up.

Elevated PowerShell:

```powershell
Get-NetIPInterface -InterfaceIndex 10 | Set-NetIPInterface -InterfaceMetric 100
```

Then confirm the lab NIC now loses to Wi-Fi, and that the default route still
points at the house router:

```powershell
Get-NetIPInterface | Sort-Object InterfaceMetric | Format-Table ifIndex, InterfaceAlias, InterfaceMetric, ConnectionState
```

```powershell
Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Format-Table ifIndex, NextHop, RouteMetric, InterfaceMetric
```

A manual metric is sticky across reboots, but it is per-interface — a new
NIC, a re-created adapter, or a different machine joining the lab segment
gets Windows' automatic metric again and needs this repeated.

### Symptom: link never came up

On first connection, with the cable seated at both ends:

| Where | What it reported |
|---|---|
| `Get-NetAdapter` | `Status: Disconnected`, `LinkSpeed: 0 bps` |
| `Get-NetIPInterface` / adapter state | `MediaConnectionState: Disconnected` |
| IP address | self-assigned APIPA, `169.254.x.x` |
| hEX `ether2` port LED | **green and blinking, the whole time** |

The APIPA address is a consequence, not a separate fault: no link means no
DHCP, so Windows falls back to self-assignment. Chasing the `169.254`
address as if it were a DHCP problem is the wrong branch.

### The diagnostic that split it: a lit router LED with a dead host link

This is the part worth keeping, more than the fix itself.

A **lit, blinking port LED on the router while the host reports no link** means
the link is **one-sided**: the router's PHY was seeing the PC's transmit
signal well enough to register activity, while the PC's receive path never
came up. Ethernet link-up is a mutual negotiation — both ends have to agree —
so an asymmetric result localizes the fault to the end that *isn't*
satisfied.

That single observation ruled the router out. It meant no time spent on the
things that look plausible from the host side and were all wrong here: the
cable, the router port, `ether2`'s configuration, RouterOS defaults.

Generalized: **check both ends' link indicators before touching either end's
configuration.** Two dead LEDs is a cable/port/physical problem. One lit LED
is a negotiation problem on the dark side.

### Root cause: Energy Efficient Ethernet (802.3az)

`Energy Efficient Ethernet` was `On` in the I219-V's advanced driver
properties. EEE has to be negotiated by *both* link partners, and it commonly
fails against small vendor switches and routers — the host waits for an
agreement the other end never completes, and the receive path stays down.
That is exactly the asymmetry the LED showed.

Inspect what the NIC is currently advertising:

```powershell
Get-NetAdapterAdvancedProperty -Name 'Ethernet' | Format-Table DisplayName, DisplayValue
```

### Fix

Elevated PowerShell:

```powershell
Set-NetAdapterAdvancedProperty -Name 'Ethernet' -DisplayName 'Energy Efficient Ethernet' -DisplayValue 'Off'
```

The link came up **immediately** — 1 Gbps full duplex, DHCP lease
`192.168.88.254/24` from the hEX, 0 ms ping to `192.168.88.1`. Verify:

```powershell
Get-NetAdapter -Name 'Ethernet' | Format-Table Name, Status, LinkSpeed, FullDuplex
```

```powershell
Test-Connection 192.168.88.1 -Count 4
```

Advanced-property changes survive reboots but **not necessarily a driver
update**, which can reset adapter defaults. If the link ever dies again after
a driver or Windows update, re-check EEE first.

### Not the fix: Ultra Low Power Mode

`Ultra Low Power Mode` on the same NIC is still `Enabled` and was never
touched. It is recorded here so it isn't "discovered" and disabled later as a
guessed remedy — turning EEE off was sufficient on its own, and leaving ULPM
alone keeps the change minimal and the causal story clean.
