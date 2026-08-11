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

## Quick checklist — WireGuard won't handshake

1. Is ether5 **link-ok** and dhcp-client **bound**?
   `ssh lab-router "/interface ethernet monitor ether5 once"` and
   `"/ip dhcp-client print"`. `stopped` / `no-link` is cabling, not keys.
2. Does the PC reach the house-side address?
   `ping 192.168.1.164` (or whatever ether5 bound). No reply → same L2/L3
   path problem; fix before debugging crypto.
3. Is UDP/51820 accepted **above** the `!LAN` drop?
   `ssh lab-router "/ip firewall filter print"`. Missing accept → packets
   never become a handshake. Stats on that rule rising with still-zero
   handshake ⇒ keys, not firewall.
4. Do client private and router peer public match?
   On Windows: `Get-Content client.private -Raw | & "C:\Program Files\WireGuard\wg.exe" pubkey`
   On router: `peers print proplist=interface,public-key,allowed-address`.
   Mismatch was the long failure mode on 2026-08-11 — see
   [WireGuard bring-up](#2026-08-11--wireguard-endpoint-live-house-uplink-on-ether5).
5. Testing from house wifi with the **public** IP as Endpoint? Many VZ
   routers lack hairpin NAT. Use `Endpoint = <ether5-ip>:51820` at home;
   use the public IP only from cellular / off-site.
6. Never paste `private-key=` or `client.private` into chat. Use
   `print proplist=name,public-key,listen-port` so RouterOS does not dump
   the server private key.

---

## Quick checklist — Netinstall starts but the board never appears

1. Is the board actually armed? `ssh lab-router "/system routerboard settings
   print"` — anything other than `try-ethernet-once-then-nand` means it will
   not offer itself, and the server will wait forever. **The arm is spent by
   any boot**, so a router that has restarted since it was provisioned is no
   longer armed. See [the arm is single-use](#the-arm-is-single-use-which-the-rest-of-this-repo-did-not-account-for).
2. Not armed and unreachable? That is the reset-button hold, per the header of
   [reprovision.sh](../provisioning/reprovision.sh).
3. Armed and still nothing? Check the link is `UP` and that `-i` names the lab
   interface — see [the lab-link checklist](#quick-checklist--lab-link-wont-come-up).

---

## 2026-08-11 — WireGuard endpoint live (house uplink on ether5)

Roadmap item 2. Design is [decisions/009](../decisions/009-wireguard-endpoint-and-uplink.md).
Scripts: `provisioning/default-config.rsc` (secret-free half),
`provisioning/apply-wireguard.sh` (keys on the Pi).

### Where the hardware lives now

The Pi (`goguma`) and hEX moved next to the house/VZ router. The PC stays in
another room on house wifi only — **no** long Ethernet back to the desk.

| Cable | Ends |
|---|---|
| Short | Pi ↔ hEX **ether1** (management / Netinstall) |
| Short | hEX **ether5** ↔ house/VZ **LAN** port (not WAN) |
| None | PC ↔ hEX |

Control path from the desk:

```text
PC (wifi) → ssh sanlee@goguma → ssh lab-router (192.168.99.1 via ether1)
```

Username on the Pi is **`sanlee`**, not `sanle`. Password/SSH failures that
look like "wrong password" were wrong user on first contact from the PC.

### Verified working state (2026-08-11 evening)

| Check | Result |
|---|---|
| ether5 | `link-ok`, 1 Gbps |
| dhcp-client on ether5 | **bound** `192.168.1.164/24` (reserve this on VZ) |
| NAT masquerade out WAN | present |
| `wg-lab` | running, listen **51820**, tunnel **10.99.0.1/24** |
| Peer | client `10.99.0.2/32`, pubkey must match PC `client.private` |
| From PC with WG Active, Endpoint `192.168.1.164:51820` | `ping 10.99.0.1` and `ping 192.168.88.1` both reply |

Server public key at verification (safe to store in client config):

```text
X5T3YGWYErmWi1kF8bSG4WsqYgi/QTYkJSphESoEU0E=
```

If `wg-lab.private` on the Pi is ever regenerated, this public key changes —
always re-read with:

```bash
ssh lab-router '/interface wireguard print proplist=name,public-key,listen-port'
```

### Key material (never in git)

On **goguma**:

```text
~/.config/netops-lab/wg-lab.private        # server private, mode 600, ~44 chars + newline
~/.config/netops-lab/wg-client-san.public  # laptop public, must match client.private
```

On **PC** (example path used in bring-up):

```text
C:\Users\sanle\client.private             # laptop private — backup offline, not git
```

`wg-lab.private` that is ~23 bytes is truncated and will fail with
`invalid private key` on apply. Re-export a full key from a temporary
RouterOS interface if that happens.

Apply / refresh tunnel after keys exist:

```bash
# on goguma
cd ~/netops-lab
./provisioning/apply-wireguard.sh
```

`reprovision.sh` calls the same script when `wg-lab.private` exists.

### Windows client (WireGuard app)

Install from https://www.wireguard.com/install/ — the GUI does not put `wg`
on PATH by default. Pubkey check in PowerShell:

```powershell
Get-Content C:\Users\sanle\client.private -Raw | & "C:\Program Files\WireGuard\wg.exe" pubkey
```

Home-LAN test tunnel (hairpin-safe):

```ini
[Interface]
PrivateKey = <client.private one line>
Address = 10.99.0.2/32

[Peer]
PublicKey = <wg-lab public-key from proplist print>
Endpoint = 192.168.1.164:51820
AllowedIPs = 10.99.0.0/24, 192.168.88.0/24, 192.168.99.0/30
PersistentKeepalive = 25
```

Off-site: set `Endpoint` to the house public **IPv4** (not IPv6 from
ifconfig.me, not the URL `https://ifconfig.me`) and forward **UDP 51820 →
192.168.1.164** on the VZ router. Confirm public IPv4 via
https://ipv4.icanhazip.com .

### Failure modes that burned time

**1. Peer public key ≠ `wg pubkey` of `client.private`.**
Symptoms: firewall WG accept counters climb (packets arrive), peer
`endpoint-port` stays 0, tunnel pings fail. Cause: laptop private key file
and `wg-client-san.public` / router peer drifted across regenerations.
Fix: derive pubkey from the PC file, scp to
`~/.config/netops-lab/wg-client-san.public`, re-run `apply-wireguard.sh`,
confirm `peers print proplist=...` matches, then Activate.

**2. ether5 `no-link` / dhcp `stopped`.**
Not a RouterOS bug — wrong port, bad cable, or not on a house LAN port.
ether1 stays Pi; only ether5 goes to VZ LAN.

**3. `Endpoint = https://ifconfig.me:51820`.**
That hostname is a lookup site, not an endpoint. Use dotted IPv4 or the
house LAN address of ether5.

**4. Public IPv6 as Endpoint while port-forward is IPv4.**
ifconfig.me can show IPv6 first; WG + VZ forward here are IPv4.

**5. Assuming missing 51820 accept when `print where dst-port=51820` looks empty.**
Live filter can still carry the default-config rule
(`in-interface-list=WAN`, comment mentions WireGuard). Read full
`/ip firewall filter print` and check order vs the `!LAN` drop. Duplicate
accepts added below the drop do nothing useful.

**6. Pasting multi-line SSH commands that break RouterOS quotes.**
Keep `/ip firewall filter add ...` on one physical line, or use a
`/system script` wrapper.

**7. Chat / logs and private keys.**
`/interface wireguard print detail` prints **private-key=**. Prefer
`proplist=name,public-key,listen-port`. If a private key hits a log, rotate
server and/or client keys.

### Still open after this session

- VZ DHCP reservation + UDP 51820 port-forward for off-site Endpoint (public
  IPv4) — home-LAN path verified; internet path not fully closed in-session.
- `apply-wireguard.sh` summary lines for server pubkey / ether5 lease were
  empty under the old `get` parsing; prefer RouterOS `:put [/interface
  wireguard get ... public-key]` style when fixing the script.

---

## 2026-08-03 — the arming line ran, and the arm is single-use

Two findings. The first closes the question this repo has carried open since
07-26; the second corrects a claim the README, ADR-005 and `reprovision.sh` all
make.

### `try-ethernet-once-then-nand` reverts the stored value when consumed

MikroTik documents that a device stops offering Etherboot after one boot. What
it does not document — checked against the
[RouterBOOT](https://help.mikrotik.com/docs/spaces/ROS/pages/136839241/RouterBOOT),
[RouterBOARD](https://help.mikrotik.com/docs/spaces/ROS/pages/40992878/RouterBOARD)
and [Netinstall](https://help.mikrotik.com/docs/spaces/ROS/pages/24805390/Netinstall)
pages — is what happens to the *stored setting*. That is the part everything
below turns on, and the answer is that it reverts to
`nand-if-fail-then-ethernet`, RouterBOOT's factory default.

Measured directly. No Netinstall server was listening, so the attempt falls
through to NAND and the board boots normally — which is what makes this test
free rather than a wipe:

```bash
pgrep -af netinstall-cli      # MUST print nothing, or this sequence is a wipe
ssh lab-router "/system routerboard settings set boot-device=try-ethernet-once-then-nand"
ssh lab-router "/system routerboard settings print"   # try-ethernet-once-then-nand
ssh lab-router "/system reboot"
ssh lab-router "/system routerboard settings print"   # nand-if-fail-then-ethernet
```

### Therefore the provisioning script's arming line ran

This is the question ADR-005 and `default-config.rsc` left open, and it is
answered by inversion rather than by another wipe cycle.

The 07-26 Netinstall *required* an Etherboot to reach setup mode. That boot
consumed the one-shot and left `boot-device` at the factory default. The board
then rebooted into the freshly installed RouterOS, and the reading taken
afterwards was `try-ethernet-once-then-nand`. Exactly one thing runs between
those two moments: the custom default-configuration script. So the arming line
ran.

### The arm is single-use, which the rest of this repo did not account for

A provisioned router is armed for exactly **one** boot. Any restart spends it,
whether or not a Netinstall server was listening.

This board was sitting at the factory default when this session opened, because
a power event earlier that day restarted both it and the Pi with nothing
serving. Router uptime `8h41m`, `uptime -s` on goguma `2026-08-03 11:01:08` —
one event, both boxes. The empty `ssh-agent` was the same event showing through.

**Consequence for the documented cycle.** "Start Netinstall on the Pi, then
power-cycle the router" only works if the router has not rebooted since it was
provisioned. Otherwise the board boots straight back into RouterOS and the
server waits forever. Not hypothetical — it was this board's actual state.

**Consequence for item 4, which is the one to carry forward.** ADR-005 arms at
provision time precisely because a locked-out router cannot be armed after the
fact, and one shot is all that case needs. But the shot is spent by any
intervening reboot from any cause, so the recovery path is live only until the
next restart. A lockout that follows a reboot needs the reset button, and the
safety net item 4 leans on is thinner than ADR-005 assumed.

### A soft reboot triggers Etherboot, so the cycle needs no power cycle

The stored value can only revert if RouterBOOT actually performed the attempt,
and it reverted across a plain `/system reboot` issued over SSH. RouterBOOT runs
its `boot-device` logic on a soft reboot exactly as it does on a power cut. The
plug was never the trigger; any boot is.

`/system reboot` also returns cleanly over a non-interactive SSH with no
confirmation prompt — the same interactive-only pattern as the forced
first-login password change.

Together those make a wipe cycle drivable end to end from the Pi: arm over SSH,
reboot over SSH, let the waiting server catch the board. `reprovision.sh` now
does exactly that — see [decisions/008](../decisions/008-unattended-wipe-cycle.md).

One ordering constraint from that work is worth having here rather than only in
the script: **the server must be listening before the reboot is issued.** Get it
backwards and the board Etherboots into nothing, falls through to NAND, and
spends the arm — so the retry needs a re-arm first, and a cycle that looked
merely slow has actually moved backwards.

### The reasoning error, which is the part worth keeping

The 07-26 reading was filed as ambiguous because a competing explanation
existed: `boot-device` is a RouterBOOT setting, and MikroTik confirms Netinstall
"does not erase the RouterOS license key, nor does it reset RouterBOOT related
settings" — so the hand-set value could have survived the format.

Every clause of that is true, and it is still not an explanation for *this*
reading, because the Netinstall's own Etherboot sits between the hand-setting
and the observation, and consumes it.

The alternative was checked for plausibility and never for consistency with the
sequence that produced the observation. **A competing explanation is only
competing if it survives the actual order of events.** The evidence was strong
on the day it was collected and was recorded as ambiguous for a week.

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

### The password prompt, and why it turned out not to matter

**RouterOS demands an interactive password change on first login.** Netinstall
leaves `admin` with a blank password; key auth gets you in, and the prompt
appears anyway.

**It is interactive-only.** A non-interactive SSH bypasses it completely:

```bash
ssh admin@192.168.99.1 "/system resource print"
```

prints the table with no prompt at all, on a board with 2m uptime. So a script
driving this router unattended never meets it, and the provisioning script
needs no `/user set` line. The router side of zero-touch is intact.

### The two prompts that DO block automation are on the Pi

That same test surfaced both, hidden until then behind interactive habits:

```
Are you sure you want to continue connecting (yes/no/[fingerprint])? yes
Enter passphrase for key '/home/sanlee/.ssh/id_ed25519':
```

Neither stops a human. Both stop a script. Zero-touch moved from the router to
the host driving it.

**The host-key prompt is permanent, not incidental.** Netinstall regenerates
the router's SSH host keys, so its identity legitimately changes every cycle.
Don't paper over it with `StrictHostKeyChecking no` — give the router its own
known-hosts file so a wrapper can clear one file per cycle:

```
Host lab-router
    HostName 192.168.99.1
    User admin
    IdentityFile ~/.ssh/id_ed25519
    AddKeysToAgent yes
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ~/.ssh/known_hosts.lab
```

`accept-new` takes a first-seen key silently but still refuses a *changed* one
mid-cycle, which is the case actually worth hearing about.

**The passphrase** is handled with a persistent `ssh-agent` — a systemd user
service plus `loginctl enable-linger sanlee`, without which systemd tears down
user services when the last SSH session closes and the agent dies on every
logout.

```bash
systemctl --user enable --now ssh-agent
sudo loginctl enable-linger sanlee
echo 'export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent.socket"' >> ~/.bashrc
ssh-add ~/.ssh/id_ed25519
```

Known limitation, chosen deliberately (see
[decisions/006](../decisions/006-management-surface-on-ether1.md)): the agent
needs a human to unlock it after every Pi reboot. The wipe loop is unattended
within a session, not across a Pi restart.

End-to-end test, which should print with no prompts of any kind:

```bash
ssh lab-router "/system resource print"
```

### One ambiguity, recorded rather than glossed

**RESOLVED 2026-08-03 — the arming line ran. See
[the 08-03 entry](#2026-08-03--the-arming-line-ran-and-the-arm-is-single-use).
The reasoning below is kept because the error in it is the useful part.**

`boot-device` came back armed — but `boot-device` is a **RouterBOOT** setting
and may survive a NAND format independently of RouterOS. So this run cannot
distinguish *"the script's arming line ran"* from *"the value we set by hand
simply persisted."* Both produce the same output. It matters because a truly
factory board starts at `routerboard: no`, where that line would fail. Settle
it by setting `boot-device=nand`, re-running the cycle, and seeing which value
comes back.

The flaw: the two explanations do *not* both produce this output. Netinstall
reaches setup mode by Etherbooting, which consumes the one-shot and resets the
value — so persistence cannot survive the sequence, and the proposed wipe test
was never needed. A soft reboot with nothing listening settled it for free.

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
