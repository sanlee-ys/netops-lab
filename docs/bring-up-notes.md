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

## 2026-07-26 — first Netinstall, end to end

Factory-blank to fully configured on **one power cycle**. No button hold, no
console, no serial adapter. This is roadmap item 1's core claim demonstrated
rather than argued.

### The command, as run

```bash
cd ~/netinstall
sudo qemu-i386-static ./netinstall-cli -i eth0 -r \
    -s ~/netops-lab/provisioning/default-config.rsc routeros-7.20.8-arm.npk
```

**`-i eth0` is a safety flag, not a tidiness one.** netinstall-cli runs its own
BOOTP server. The Pi is dual-homed onto the house network, and an unbound
server would answer on `wlan0` as well — a rogue BOOTP service on the LAN the
household actually uses. Bind it to the lab link.

`sudo` because BOOTP and TFTP need privileged ports. `-r` applies the default
configuration and `-s` makes that configuration ours; the two compose, which
the usage text implied and this run confirmed.

### Output of a good run

```
Waiting for Link-UP on eth0
Using client IP 192.168.99.1
Waiting for RouterBOARD...
Assigned 192.168.99.1 to D0:EA:11:BE:0D:B2
Booting device ... into setup mode
Formatting device ...
Sending packages to device ...
Packages and configuration script sent to device ...
Rebooting device ...
Successfully finished installing device ...
```

Start the server first, *then* power-cycle the router. With
`boot-device=try-ethernet-once-then-nand` already armed there is no button
timing involved — the board offers itself on boot and falls through to NAND if
nothing answers.

### Two failure modes hit on the way, both cheap

**`Invalid user script path`.** netinstall-cli validates the script path
*before* touching the router. Worth appreciating rather than just fixing: a
tool that opened the flash session first and then discovered it couldn't read
the script would leave a half-wiped device.

**`NO-CARRIER` on the Pi with the address configured correctly.** `nmcli` will
happily configure an address on an unplugged interface, so a correct-looking
`ip addr` proves nothing about the link. Check `ip -br link` for `UP`, and see
the lab-link checklist at the top of this file if it stays down. In this case
the cause was that the cable had not been run yet.

### Static address on the Pi

Bookworm uses NetworkManager, so this is `nmcli` and not `dhcpcd.conf`:

```bash
sudo nmcli con add type ethernet ifname eth0 con-name lab \
    ipv4.method manual ipv4.addresses 192.168.99.2/30
sudo nmcli con up lab
```

**No gateway and no DNS, deliberately.** That is the Pi-side counterpart of
pinning the PC's interface metric: with no gateway defined, the lab link cannot
take the default route away from wifi, so the SSH session you are working in
survives. Confirm before wiping anything:

```bash
ip route show default        # must still be via wlan0
```

### Verifying afterwards, in the right order

`ping` first, but **do not read a successful ping as success.** The provisioning
script accepts ICMP with no interface restriction, so it answers whether or not
the management rule is correct. It only proves addressing came up.

The real test is one command, because it exercises the entire chain at once —
addressing, the firewall accept landing above the `!LAN` drop, the SSH key
import having run inside a first-boot script, and password login being off:

```bash
ssh admin@192.168.99.1        # from goguma, NOT from the PC
```

**From the PC this times out, and that is correct.** The PC sits on
`192.168.88.x`; the management rule accepts only `in-interface=ether1` with
`src-address=192.168.99.2`, and the PC has no route to `192.168.99.0/30` at
all. *Timed out* rather than *refused* is the tell that packets had nowhere to
go rather than being rejected.

Then confirm the config is ours:

```
/system device-mode print          # routerboard: yes
/system routerboard settings print # boot-device: try-ethernet-once-then-nand
/ip address print                  # 192.168.99.1/30 and 192.168.88.1/24
/ip firewall filter print          # management accept ABOVE the !LAN drop
/ipv6 firewall filter print        # four input rules ending in the !LAN drop
/ip ssh print                      # always-allow-password-login: no
/ip firewall nat print             # empty
/user ssh-keys print
```

### The finding that mattered most

**device-mode survives a Netinstall.** `routerboard: yes` came back intact
after a full format. That decides a question that was going to force a
RouterOS 7.22 upgrade: enabling the flag is a one-time per-device bootstrap,
not something every wipe cycle has to repeat.

### The gap that remains

**RouterOS demands an interactive password change on first login.** Netinstall
leaves `admin` with a blank password; key auth gets you in, and the prompt
appears anyway. A script-driven Pi would hit the same prompt, so "zero-touch"
still has a human in it.

The decisive and untested question is whether a *non-interactive* SSH bypasses
it:

```bash
ssh admin@192.168.99.1 "/system resource print"
```

If that runs without prompting, unattended provisioning is unaffected and the
prompt is a cosmetic property of interactive logins.

### One ambiguity, recorded rather than glossed

`boot-device` came back armed — but `boot-device` is a **RouterBOOT** setting
and may survive a NAND format independently of RouterOS. So this run cannot
distinguish *"the script's arming line ran"* from *"the value we set by hand
simply persisted."* Both produce the same output. It matters because a truly
factory board starts at `routerboard: no`, where that line would fail. Settle
it by setting `boot-device=nand`, re-running the cycle, and seeing which value
comes back.

---

## 2026-07-25 — device-mode blocks arming on a factory board

**Symptom.** On a factory hEX refresh, the command ADR-005 relies on to arm the
next Netinstall cycle simply refuses:

```
/system routerboard settings set boot-device=try-ethernet-once-then-nand
failure: not allowed by device-mode
```

**What it means.** RouterOS device-mode gates whole feature groups, and
`/system routerboard settings` sits behind a flag called `routerboard` that is
**off by default in every mode**. This board ships in `mode: home`, the most
restrictive one. Check what you actually have before doing anything:

```
/system device-mode print
```

A factory hEX comes back with `mode: home` and, notably, `scheduler: no`,
`fetch: no`, `romon: no`, `sniffer: no`, `container: no`, `routerboard: no`.
That list is worth reading in full once — it is not only about boot-device.

**Fix.** Enable the single flag, then confirm physically:

```
/system device-mode update routerboard=yes
```

The device replies with a countdown — roughly *"turn off power or reboot by
pressing reset or mode button in 4m55s to activate"* — and the timer runs on
the **device**, not in your terminal. Don't quit the display first; just pull
the power. The router reboots itself to apply, so allow 30–60s before SSH
returns.

**Use the power cycle, not the button.** The documentation offers either, but
this board's only button is the reset button, and a mistimed hold there is a
configuration reset. The power cycle is unambiguous.

Verify, then retry the original command:

```
/system device-mode print          # want routerboard: yes
/system routerboard settings set boot-device=try-ethernet-once-then-nand
/system routerboard settings print
```

**Two things this settled that the docs left ambiguous.** Individual flags can
be overridden on top of a mode — `mode: home` with `routerboard: yes` is a
valid state, despite one source suggesting the flag was settable only in ROSE
mode. And the mode is not cosmetic: `scheduler: no` and `fetch: no` will matter
to anything script-driven built on this box later.

**One thing worth taking as good news.** `romon: no` means RoMON — MikroTik's
layer-2 management overlay, reachable without IP — is off by default. That is a
third out-of-band path of the same class as MAC-Winbox and IPv6 link-local,
closed for free by the restrictive shipping mode. Don't enable it absent-mindedly.

**Still open:** whether the `routerboard` flag survives a Netinstall. If it
does, this is a one-time bootstrap. If it does not, every wipe cycle needs this
dance repeated with a power cycle, and RouterOS 7.22 — where Netinstall can set
device-mode itself via `-sm` — becomes necessary rather than optional.

---

## 2026-07-25 — netinstall-cli on the Pi under QEMU

**Host:** `goguma` (Pi 5, aarch64, Raspberry Pi OS Lite Bookworm).
**Goal:** prove the Netinstall tool executes before anything is cabled or
wiped. Per [decisions/005](../decisions/005-pi-as-ztp-host.md) this is the
timebox gate — a failure here moves item 1 to the PC rather than becoming a
QEMU debugging project.

### Measure the binary, don't argue about it

MikroTik's Linux Netinstall page does not state which host architectures the
tool is built for. One command settles it, and the answer changes the plan:

```bash
file netinstall-cli
```

```
netinstall-cli: ELF 32-bit LSB executable, Intel i386, version 1 (SYSV),
statically linked, stripped
```

Two things matter in that line. **i386**, not x86-64 — so the emulator is
`qemu-i386-static`, and reaching for `qemu-x86_64-static` will fail
confusingly. And **statically linked**, which is the lucky part: the usual
expense of user-mode QEMU is providing a 32-bit sysroot of shared libraries,
and a static binary needs none of it. No `-L`, no multiarch, no `:i386`
packages.

### Setup

```bash
cd ~/netinstall
wget https://download.mikrotik.com/routeros/7.20.8/netinstall-7.20.8.tar.gz
wget https://download.mikrotik.com/routeros/7.20.8/routeros-7.20.8-arm.npk
tar -xzf netinstall-7.20.8.tar.gz
sudo apt install -y qemu-user-static
```

The package is `arm`, not `arm64` — the hEX refresh reports
`architecture-name: arm` (32-bit). Installing the wrong architecture's `.npk`
is a slow way to find that out.

### Run

```bash
qemu-i386-static ./netinstall-cli
```

Printing its version and usage is the pass condition. No root needed for this
step; root is only required for an actual install, because BOOTP and TFTP bind
privileged ports.

Debian registers binfmt handlers with `qemu-user-static`, so plain
`./netinstall-cli` may work with no emulator prefix. Worth trying first, but
the explicit form is what was verified here.

### What the usage output settled

Reading it carefully answered two questions that had been open on
documentation alone:

- **`-sm` is not in this build's options.** That matches the documented
  RouterOS/Netinstall 7.22 floor, now confirmed rather than assumed. 7.20.8
  does not have it.
- **`-r` and `-s` compose.** The only mutual exclusion the tool declares is
  `-r`/`-e`. Since the usage also says *"by default existing configuration will
  be kept"*, `-r` is what makes the default configuration apply — and with
  `-s`, that default configuration is ours. `-r -s <script>` is the invocation.

Also note `{-i <interface> | -a <client-ip>}` is braced: one of the two is
mandatory, not optional.

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
