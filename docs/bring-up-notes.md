# Bring-up notes

Field notes from physically bringing this lab's hardware up: what broke, what
the symptom actually meant, and what fixed it. Troubleshooting and runbook
material only — decisions live in [decisions/](../decisions/), and nothing
here is an ADR.

Entries are newest-first and dated. Host-side commands are PowerShell on
San's PC (Windows 11); anything that changes adapter or interface settings
needs an **elevated** shell.

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
