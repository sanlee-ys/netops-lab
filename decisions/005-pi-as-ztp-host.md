# ADR-005: The Pi is the ZTP host — Netinstall-driven, armed for repeat cycles

**Status:** Accepted
**Date:** 2026-07-25
**Deciders:** San Lee

## Context

Roadmap item 1 (ZTP + Netinstall closure) gates everything else in this lab,
but the README named the Pi only as "agent host" — leaving unstated who
actually serves provisioning. Two things were checked against vendor
documentation before designing anything.

**RouterOS has no DHCP-option ZTP.** There is no first-boot mechanism that
pulls a configuration from a DHCP-advertised URL — nothing resembling the
RFC 8572 / BRSKI flow that [decisions/004](004-research-standing-of-the-agent-experiment.md)
cites as settled trust substrate. Two paths actually exist:

- **Netinstall-driven.** `netinstall-cli` runs its *own* BOOTP + TFTP server,
  pushes the RouterOS `.npk`, and applies configuration through one of two
  hooks: `-s <userscript>` installs a custom default-configuration script
  that replaces MikroTik's, and `-sm <modescript>` runs a one-time script on
  the first boot after install (v7.22+).
- **TR-069/CWMP**, with the ACS URL delivered in DHCP option 43. Closer in
  shape to a standards-based bootstrap, but it requires running an ACS, and
  there are user reports of RouterOS's TR-069 package not consuming option 43.

An early working assumption — that the Pi would run a DHCP server with
options 66/67 pointing at an `.rsc` — was wrong, and is recorded here so it
isn't re-derived. Netinstall carries its own BOOTP/TFTP and needs no external
DHCP server.

**`netinstall-cli` is an x86 binary** and will not run natively on the Pi's
aarch64. User-mode QEMU (`qemu-user-static` / `qemu-i386`) runs it without a
full VM. Root is required either way, because BOOTP and TFTP bind privileged
ports.

## Decision

**1. ZTP in this lab means Netinstall-driven provisioning.** TR-069 is not
pursued. It would add an ACS to the critical path and put a documented
RouterOS quirk between the lab and its first deliverable, in exchange for a
resemblance to standards that ADR-004 already says this build is not being
judged against. The closure being chased is a reliable wipe-to-provisioned
cycle, and Netinstall delivers exactly that.

**2. The Pi is the Netinstall host; the PC is a timeboxed fallback.** The Pi
runs `netinstall-cli` under user-mode QEMU. If that path is not working
within a fixed timebox on bring-up day, item 1 proceeds on the PC with the
vendor-supported x86 build and the Pi migration becomes follow-up work.

Hosting on the Pi is the goal because the Pi is the always-on, wifi-reachable
box that later hosts the agent — putting provisioning there makes the whole
cycle scriptable from one place, which is the harness property item 4 needs.
The fallback exists so that an emulation problem cannot block a
hardware-fidelity deliverable: debugging QEMU is not debugging ZTP.

**3. The provisioning script arms the next cycle.** The custom
default-configuration script sets:

```
/system routerboard settings set boot-device=try-ethernet-once-then-nand
```

so every provisioned router already offers itself to a Netinstall server on
its next boot, then falls through to NAND when none answers. A wipe becomes
"start Netinstall on the Pi, power-cycle the router" instead of holding the
reset button with correct timing.

**Arming happens at provision time, not at wipe time.** This is load-bearing:
the command requires a reachable, running device. If an agent later leaves
the router running-but-unreachable — precisely the failure item 4 exists to
study — there is no opportunity to arm it after the fact.

**Topology consequence.** On the RB750Gr3, Netinstall boots from ether1. The
Pi has a single NIC, so its lab-side link goes to **ether1**, and the Pi sits
on what the stock configuration treats as the WAN side. MikroTik's default
configuration makes ether1 a DHCP client behind a firewall that drops input
from WAN — which would firewall the Pi out of the device it provisions.
Permitting management from the Pi's subnet on ether1 is therefore the
substantive content of the custom default-configuration script, not an
afterthought. It is also the exact surface the lockout experiment will later
attack.

## Consequences

**What this buys:** a provisioning path with one moving part instead of
three, hosted on the box that is already always-on and reachable over wifi.
A wipe cycle that needs one physical action (power) rather than a timed
button hold. And a custom default-configuration script whose contents are now
well-defined — it must open management on ether1, and it must arm the next
boot.

**What this costs:** QEMU on the provisioning path, which is a dependency the
PC route would not have. The fallback bounds that cost rather than removing
it. Power-cycling remains a physical action, so the cycle is repeatable but
not yet unattended.

**What this forecloses:** nothing permanently. TR-069 can be revisited as a
separate scenario if an ACS ever becomes interesting on its own merits; this
decision only keeps it off item 1's critical path.

## Deferred

- **Remote power control** (smart plug or relay HAT) would make the wipe loop
  fully unattended. It is new hardware, so [decisions/001](001-hardware-substrate-scope.md)
  requires a specific need before buying — likely worth revisiting when item
  4 wants trial volume, not now.
- **Serial console via USB-TTL.** The hEX has no RS232 header, but forum
  reports describe reaching its serial console through the USB port with a
  USB-TTL adapter (GND/TX/RX, TX/RX crossed). This is the true out-of-band
  path and it is cheap, but it is forum-sourced rather than confirmed against
  MikroTik documentation, and it is new hardware. Verify before buying.

## Alternatives Considered

| Option | Reason Not Chosen |
|--------|-------------------|
| TR-069 / CWMP with ACS URL in DHCP option 43 | Requires running an ACS and carries reported RouterOS option-43 handling problems; puts a debugging rabbit hole ahead of item 1 for a standards resemblance the build is not judged on |
| Hand-rolled DHCP + TFTP on the Pi serving an `.rsc` | Based on a wrong assumption — Netinstall already provides BOOTP and TFTP; building a parallel one adds a component with no job |
| Keep Netinstall on the PC permanently | Leaves the provisioning cycle attended and split across two machines, which is the opposite of the repeatable harness item 4 depends on |
| Prove it on the Pi with no fallback | Puts QEMU emulation on the critical path of a hardware bring-up day, where a failure would stall the gating deliverable |
| Trigger wipes by holding the reset button | Works, but every cycle needs correct button timing with a person present — the tedium that stops repeat runs from happening |
