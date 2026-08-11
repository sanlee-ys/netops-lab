# ADR-009: WireGuard endpoint on the hEX, house uplink on ether5

**Status:** Accepted
**Date:** 2026-08-11
**Deciders:** San Lee

## Context

Roadmap item 2 is a WireGuard endpoint so the lab pays back on days it is not
physically reachable. [decisions/006](006-management-surface-on-ether1.md)
already deferred two pieces of the shape without choosing them:

- **Masquerade** was omitted from the baseline because ether1 is the Pi link,
  not an upstream. It returns with a real uplink.
- **The uplink port** has to come out of the bridge: ether1 is taken by the
  Pi, so internet cannot arrive there.

WireGuard on RouterOS is the right product surface (native, no container on
the router — [decisions/003](003-on-router-containers.md)). The open work is
where the uplink lands, how keys survive a wipe, and how this interacts with
the lockout experiment.

Constraints that bite:

1. **This repo is public.** A WireGuard private key must never ship in
   `default-config.rsc` or any committed file.
2. **Wipes are routine** ([decisions/008](008-unattended-wipe-cycle.md)). A
   server key that regenerates every Netinstall forces every client to
   re-pair; that taxes the exact "reach the lab from away" use case.
3. **Item 4 measures Pi lockout on ether1 SSH**, not "San has no path left on
   earth." A remote recovery path for the human is a feature, not a cheat, as
   long as it does not give the *Pi* a back door under the management rule.

## Decision

**1. House uplink is ether5, off the bridge.**

ether2–ether4 stay on `bridge` (lab LAN, `192.168.88.0/24`). ether5 is removed
from the bridge, joins the `WAN` interface list, and runs a DHCP client toward
the house LAN (or whatever upstream is cabled there).

ether1 stays the Pi point-to-point management link and stays in `WAN` for the
forward-policy framing ADR-005/006 chose. It is still not the internet
uplink.

**2. Masquerade returns, out the WAN list.**

```
/ip firewall nat
add chain=srcnat out-interface-list=WAN action=masquerade \
    comment="lab: NAT lab clients out the house uplink"
```

Lab hosts on the bridge reach the house (and beyond) through the hEX. Traffic
from ether1's Pi link is still covered by the existing forward drop for new
WAN connections that are not DSTNATed — the Pi does not become a free router
into the lab LAN.

**3. WireGuard listens on the hEX (`wg-lab`), not on the Pi.**

| Field | Value |
|---|---|
| Interface | `wg-lab` |
| Listen port | `51820/udp` |
| Tunnel address | `10.99.0.1/24` |
| First peer (San) | `10.99.0.2/32` |
| Peer allowed addresses (server side) | `10.99.0.2/32` |
| Client allowed addresses (typical) | `10.99.0.0/24`, `192.168.88.0/24`, `192.168.99.0/30` |

`wg-lab` is added to the **LAN** interface list so tunnel traffic is not
killed by the `!LAN` input drop, and so San can SSH to the router and reach
lab hosts over the tunnel without a second special-case rule pile.

Input accepts UDP/51820 on `in-interface-list=WAN` (the house-facing path).
The house router still has to port-forward `51820/udp` to ether5's lease;
that is outside this repo and is documented in the README rather than
automated.

**4. Private keys live on the Pi; the baseline script does not embed them.**

- Server private key: `~/.config/netops-lab/wg-lab.private` on `goguma`
  (mode `0600`, never git).
- San client public key: `~/.config/netops-lab/wg-client-san.public` on
  `goguma`.
- `provisioning/apply-wireguard.sh` (run on the Pi, against `lab-router`)
  creates or updates `wg-lab`, the address, the peer, and is idempotent.

`default-config.rsc` carries only the **secret-free** half: ether5 uplink,
DHCP client, masquerade, and the UDP/51820 accept. After every successful
wipe cycle, WireGuard is re-applied from the Pi-held key so the server
identity is stable across Netinstalls.

`reprovision.sh` invokes `apply-wireguard.sh` when that key file exists, and
skips cleanly when it does not — so a fresh Pi clone without keys still
provisions, and item 2 is opt-in by dropping two files in place.

**5. WireGuard is not a Pi management path.**

No change to the ether1 SSH accept (`src-address=192.168.99.2`, port 22).
The lockout experiment still has one narrow rule to attack from the agent
host. San's laptop over `wg-lab` is human remote access; MAC-Winbox on the
LAN bridge remains the on-site human recovery path (ADR-006).

## Consequences

- Cabling: ether5 must reach the house LAN (or other upstream). Lab devices
  and San's PC use ether2–4 only.
- House router: DHCP reservation for the hEX WAN MAC + UDP 51820 forward.
  Without that, WireGuard only works from inside the house LAN.
- A wipe without `apply-wireguard.sh` leaves uplink/NAT up but no tunnel
  until the script runs — visible, fail-soft.
- Item 4 gains a remote human path; it does not gain a Pi back door.
- Client config (phone/laptop) is generated once against the stable server
  public key printed by `apply-wireguard.sh`.

## Alternatives considered

| Option | Why not |
|---|---|
| WireGuard on the Pi instead of RouterOS | Works, but abandons the README's "RouterOS 7 native" goal and puts remote entry on the agent host item 4 may isolate |
| Auto-generated server key inside `default-config.rsc` each wipe | Simple, and every client breaks every cycle |
| Private key committed to the public repo | Unacceptable |
| Uplink on ether2 | Works, but burns the first lab-facing port; ether5 keeps the usual "last port is WAN" muscle memory |
| Put `wg-lab` in WAN list | Would require a stack of input exceptions; LAN-list membership matches "this is a trusted tunnel into the lab" |
| Full default-config include of peer public key only, keygen on router | Server key still rotates unless exported and reinjected — same as decision 4 with more moving parts |
