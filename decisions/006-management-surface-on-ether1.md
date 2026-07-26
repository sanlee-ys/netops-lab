# ADR-006: The management surface the provisioning script opens on ether1

**Status:** Accepted
**Date:** 2026-07-25
**Deciders:** San Lee

## Context

[decisions/005](005-pi-as-ztp-host.md) established that the custom
default-configuration script must open management for the Pi on ether1, and
that keeping MikroTik's WAN framing there is a deliberate choice made so item
4 has a real deny-by-default policy to attack. It did not say how wide that
opening should be, how the Pi authenticates, or what out-of-band paths survive
it. Those are the decisions here.

They were made against the hEX's **actual** default configuration, read off
the board on 2026-07-25 (RouterOS 7.20.8 long-term, factory-software 7.20,
model E50UG), rather than against the typical shape. Three things in that
export mattered more than expected.

**The stock input drop is `in-interface-list=!LAN`, not "from WAN."** Input is
denied unless it arrives on a LAN-list interface. ether1's WAN membership is
incidental to it; an interface in *no* list is dropped just the same. This is
stricter than ADR-005's summary implied and it is good news, because the
exception we add is then unambiguous.

**Stock accepts ICMP on the input chain with no interface restriction.** So a
host on ether1 can ping the router while being unable to manage it. On this
box reachability is not evidence that management works, which is a live
misdiagnosis risk during bring-up.

**ether1 has no address at all.** It is a DHCP *client* on an inactive
interface; the only address on the router is `192.168.88.1/24` on the bridge.
The Pi is what is plugged into ether1, and it is not going to serve the router
a lease. So the script has to stand up a management subnet that does not
currently exist, on both ends.

Separately, the netinstall hooks were checked against MikroTik's manual rather
than assumed. `-s` has **no** minimum version and installs a custom default
configuration that survives RouterOS updates and configuration resets. `-sm`
requires **RouterOS and Netinstall 7.22 or newer**, and this board is on
7.20.8. ADR-005 named both hooks as though they were co-equal; they are not.

## Decision

**1. The exception is SSH only, from the Pi's address, on ether1.**

```
add action=accept chain=input in-interface=ether1 \
    src-address=192.168.99.2 protocol=tcp dst-port=22
```

placed above the `!LAN` drop. Narrower than a blanket source-address accept,
and better practice, but the operative reason is item 4: a narrow rule can be
broken in several distinguishable ways — wrong interface, wrong source, wrong
port, wrong position in the chain — where a blanket rule mostly fails as a
single boolean. More distinguishable failure modes is the point of the
experiment, not an accident of tightening.

The cost is accepted: if Pi-side tooling later wants the RouterOS API
(8728/8729) instead of SSH, the rule has to be widened deliberately rather
than silently working already.

**2. The management link is a point-to-point `192.168.99.0/30`** — router
`.1` on ether1, Pi `.2`, both static. A /30 holds exactly two hosts, so the
addressing itself states that this is a point-to-point management link and
not a segment anything else joins. Static on both ends is forced rather than
chosen: the accept rule names a source address and the script is authored
before the router exists, so the address cannot be learned from a lease.

**3. MAC-Winbox and the MAC server stay LAN-only**, as stock has them.

This is the load-bearing one. MikroTik's MAC server is a layer-2 management
path — reach the router by MAC with no IP configured anywhere. It is the
genuine out-of-band route short of Netinstall. Leaving it restricted to the
LAN list means the Pi, on ether1, has no layer-2 fallback: an agent that
destroys IP-layer management from the Pi has actually locked the Pi out, which
is the event item 4 exists to observe. Granting it on ether1 would put a back
door underneath that exact failure.

The human safety net survives regardless, and that is why this is affordable:
San's PC is on the bridge (ether2), where MAC-Winbox still works. A lockout is
therefore observable from the Pi and recoverable from the PC, without a
Netinstall and without physical access beyond being at the desk.

**4. The Pi authenticates with an SSH public key carried in the script
itself.** A public key is not a secret, so it can be committed to this public
repository and the provisioning script stays self-contained — no credential
has to be injected at provision time and none enters git.

**5. Item 1 is designed around `-s` alone.** `-sm` is not used. Everything the
script must do — addressing, the firewall exception, arming the next boot — is
default-configuration work, so the 7.22 floor never applies and 7.20.8 does
not block the gating deliverable.

## Consequences

**What this buys:** a provisioning script that is fully self-contained and
publishable, a management path narrow enough to be an interesting target, and
a lockout that is real from the Pi's side while remaining cheap to recover
from the PC's side. It also removes 7.22 from item 1's critical path.

**What this costs:** the Pi's only route to the router is a single SSH accept
rule on a single interface with a single source address. That is the intent,
but it means a mistake in any one of those four fields during bring-up is
indistinguishable from the others until diagnosed, and ICMP will keep
answering the whole time.

**What this forecloses:** nothing permanently. Widening to the API, or adding
MAC-Winbox on ether1 for a specific debugging session, are both one-line
changes — they simply stop being properties of the provisioned baseline.

## Deferred

- **`-sm` and device-mode.** MikroTik's stated use for `-sm` is device-mode
  and protected-routerboot. RouterOS 7 gates `scheduler` and `fetch` behind
  device-mode, and changing device-mode requires a physical power cycle within
  a timeout. Item 4 is netwatch-driven and may well collide with this. Revisit
  when item 4 is scoped, which is also when moving off the 7.20 long-term
  branch to reach the 7.22 floor becomes a real question rather than a
  hypothetical.
- **Masquerade.** Stock srcnats out the WAN list. With ether1 as the Pi link
  and no upstream attached, that rule would only ever NAT router-to-Pi
  traffic, which is not wanted. It is left out of the script and comes back
  with the real uplink in roadmap item 2.
- **The uplink port.** Five ports, with ether1 taken by the Pi, means item 2's
  internet uplink has to come out of the bridge. ether1's WAN-list membership
  is therefore a forwarding policy and a framing, not a claim that the
  internet arrives there. Stated here so it does not read as confused later.
- **IPv6.** Stock ships a substantial IPv6 filter set. The script does not yet
  reproduce it, and omitting it silently would leave IPv6 input
  accept-by-default. Either mirror the stock set or disable IPv6 outright —
  undecided, and it must be settled before the script is trusted.

## Alternatives Considered

| Option | Reason Not Chosen |
|--------|-------------------|
| Blanket accept from the Pi's source address, any protocol | One line and nothing to half-break, but a wider hole than the job needs and a poorer reference. Chiefly, it collapses item 4's failure modes into a single boolean |
| Grant MAC-Winbox to the Pi on ether1 | Makes item 1 much harder to wedge, at the price of a layer-2 back door beneath the exact failure item 4 exists to study. Lockout runs would need it disabled first, making it a thing to remember rather than a property of the config |
| Let the Pi's lab-side address come from DHCP | Impossible as sequenced — the accept rule names a source address and is authored before the router runs |
| A /24 for the management link | Works, but implies a segment other hosts may join. The /30 documents the point-to-point intent in the addressing |
| Password authentication for the Pi | Puts a secret on the provisioning path. Either it is committed to a public repo, or the script stops being self-contained and needs injection at provision time. A public key has neither problem |
| Wait for 7.22 to use `-sm` | Buys nothing item 1 needs, and would put a RouterOS branch migration ahead of the gating deliverable |
