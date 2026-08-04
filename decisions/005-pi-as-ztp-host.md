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

**Confirmed on hardware 2026-07-25.** `file` reports the 7.20.8 build as
`ELF 32-bit LSB executable, Intel i386, statically linked`. Two things follow.
It is **i386**, not x86-64, so `qemu-i386-static` is the correct emulator. And
it is **statically linked**, which removes the usual expensive part of
user-mode emulation — no 32-bit sysroot, no `-L`, no multiarch setup. It runs
on `goguma` under `qemu-i386-static` and prints its usage. **The PC fallback in
decision 2 below was therefore never triggered.**

The same usage output confirmed two things previously taken from
documentation: `-sm` is absent from this build's options, matching the stated
7.22 floor; and the only mutual exclusion declared is `-r`/`-e`, so `-r` and
`-s` compose. Since `-r` is what applies the default configuration and `-s`
makes that default configuration ours, `-r -s <script>` is the intended
invocation.

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

**Amended 2026-08-03 — the arm is single-use, so "not at wipe time" is wrong as
stated.** `try-ethernet-once-then-nand` is a genuine one-shot: the next boot
consumes it and RouterBOOT reverts the stored value to its default. A
provisioned router therefore offers itself to Netinstall for exactly one boot
and then silently stops.

The rationale above survives intact — a router that is unreachable cannot be
armed after the fact, and one shot is precisely what that case needs. What does
not survive is the implication that provision-time arming is *sufficient*. It
covers the lockout case and it does not cover routine cycles, because any
restart from any cause spends the shot. This decision read as "the board stays
armed"; it never did.

Two consequences follow.

The routine wipe cycle should arm immediately before rebooting, over SSH, in
the same run that starts the Netinstall server. That is additive to this
decision, not a replacement for it — both arming points are wanted, for
different failures. **Acted on the same day in
[decisions/008](008-unattended-wipe-cycle.md)**, which also removes the power
cycle this ADR treated as irreducible.

More seriously, **item 4's recovery path is thinner than this ADR assumed.**
The single shot is live only until the next restart, so a lockout that follows
a reboot has no armed board behind it and needs the reset button. Any lockout
run should verify the board is armed as part of its setup, and treat that as a
precondition rather than a property.

Evidence and method: `docs/bring-up-notes.md`, 2026-08-03.

**Device-mode precondition, discovered on hardware 2026-07-25.** The arming
command above fails with `not allowed by device-mode` on a factory board. The
hEX ships in **`mode: home`**, the most restrictive mode, and
`/system routerboard settings` is gated behind a `routerboard` flag that is
off by default in every mode. Enabling it is not a configuration change that
can be made over SSH alone:

```
/system device-mode update routerboard=yes
```

then **physical confirmation within 5 minutes** — a power cycle or a button
press — after which the device reboots itself. A power cycle is preferable on
this board: its only button is the reset button, and a mistimed hold there is
a configuration reset.

Two things this established that documentation left ambiguous. Individual
flags **can** be overridden on top of a mode (`mode: home` with
`routerboard: yes` is a valid state on a hEX); one source suggested the flag
was settable only in ROSE mode, and that is not what the device does. And
`mode: home` also has `scheduler`, `fetch`, `romon`, `sniffer` and `container`
off, which reaches well past this ADR — item 4 is netwatch-driven, and
`romon: no` is silently closing a third layer-2 back door alongside MAC-Winbox
and IPv6 link-local.

**The open question this leaves is whether the `routerboard` flag survives a
Netinstall.** If it persists, enabling it is a one-time bootstrap and the
provisioning script's arming line works on every subsequent cycle. If
Netinstall resets it, then on 7.20.8 every cycle needs a manual device-mode
update plus a power cycle before the router can be armed — which is worse than
the reset-button tedium this decision rejected, and moving to 7.22 (where
Netinstall can configure device-mode directly) stops being optional. Observe
it on the first Netinstall.

**ANSWERED 2026-07-26: it survives.** `routerboard: yes` came back intact after
a full format. Enabling the flag is a one-time per-device bootstrap, and the
7.22 upgrade stays deferred to item 4 rather than being forced into item 1.

One piece of luck worth keeping deliberate: the arming command is the **last**
statement in `provisioning/default-config.rsc`. If it aborts the script under
device-mode denial, everything else has already applied. That ordering was
incidental when written and is now load-bearing.

**Topology consequence.** Netinstall boots from the first port or a port
marked BOOT — ether1 on this board. The
Pi has a single NIC, so its lab-side link goes to **ether1**, and the Pi sits
on what the stock configuration treats as the WAN side. MikroTik's default
configuration makes ether1 a DHCP client behind a firewall that drops input
from WAN — which would firewall the Pi out of the device it provisions.
Permitting management from the Pi's subnet on ether1 is therefore the
substantive content of the custom default-configuration script, not an
afterthought. It is also the exact surface the lockout experiment will later
attack.

Keeping the WAN framing at all is a choice rather than an inheritance, and is
worth stating plainly because the first reading of this section assumed
otherwise. `-s` *replaces* MikroTik's default configuration; it does not amend
it. ether1 could equally have been authored as a plain management port with no
untrusted side, and therefore no drop rule to make an exception to. The
framing is kept because item 4 studies an agent severing its own management
path, and the canonical form of that failure is a change to a deny-by-default
firewall policy. Authoring the untrusted side away would remove the mechanism
the later experiment exists to observe. The cost is accepted knowingly: the
config calls ether1 a WAN while no WAN is attached, and management access
depends on an exception holding inside a deny policy — more moving parts than
the alternative, on the port the whole lab is reached through.

A consequence that binds the ordering: the accept rule has to name a source
address, and the script is authored before the router that will run it
exists. The Pi's lab-side address must therefore be fixed and known in
advance, not learned from a lease.

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

## Outcome, 2026-07-26

The decision held. A factory-blank board reached fully-configured on **one
power cycle**, with no button hold, no console and no serial adapter. `-r -s`
compose as designed, the Pi hosts the whole cycle under QEMU, and the PC
fallback in decision 2 was never triggered.

Two things were left open, both recorded in `provisioning/default-config.rsc`.
**Both are now closed.**

- **Netinstall leaves `admin` blank and RouterOS demands an interactive
  password change on first login.** ~~The decisive untested question is whether
  a *non-interactive* SSH bypasses the prompt.~~ **ANSWERED 2026-07-26: it
  does.** `ssh admin@192.168.99.1 "/system resource print"` prints with no
  prompt on a freshly installed board, so a script driving this router never
  meets it and no `/user set` line is needed.
- **Whether the arming line actually ran.** ~~Settle it by setting
  `boot-device=nand` and re-running the cycle.~~ **ANSWERED 2026-08-03: it
  ran** — and the proposed test was never needed. Netinstall reaches setup mode
  by Etherbooting, which consumes `try-ethernet-once-then-nand` and reverts the
  stored value to RouterBOOT's default. The armed reading taken after the cycle
  therefore could only have been written by the provisioning script; the
  "persisted through the format" alternative does not survive the sequence.
  A soft reboot with nothing listening settled it in one command. See
  `docs/bring-up-notes.md`.

The closing prediction was that both were answerable by one more wipe cycle.
Neither needed one — the first was a non-interactive SSH, the second a soft
reboot. The instinct was right in substance (the harness is the cheapest way to
ask questions about the harness) and wrong about the price, in the direction of
overestimating it. Worth noticing, because the same overestimate is what let
the arming question sit open for a week.

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
| Author ether1 as a plain management port, dropping the WAN framing entirely | Simplest config to reason about and the hardest to self-lock out of during item 1, but lab-shaped rather than field-shaped, and it deletes the deny-policy exception that item 4 exists to attack. The firewall work is deferred rather than avoided — item 2 needs a real uplink anyway |
| Netinstall over ether1, then re-cable the Pi to a LAN port for steady-state management | Sidesteps the firewall question at the price of a manual cable move in every wipe cycle — reintroducing exactly the physical tedium this ADR's arming mechanism was designed to remove. The Pi has one NIC, so it cannot hold both ports at once |
