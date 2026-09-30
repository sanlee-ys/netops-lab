# ADR-010: FRR on the Pi, with OSPF for the link, eBGP for a service prefix, and no default route

**Status:** Proposed
**Date:** 2026-09-30
**Deciders:** San Lee

## Context

Roadmap item 3 is "FRR / OSPF-BGP on the Pi". The Pi and the hEX share one
link: the `192.168.99.0/30` management link on ether1
([decisions/006](006-management-surface-on-ether1.md)). That link is also the
only path the Pi has to manage the router. Item 4 attacks that path on
purpose, so item 3 must not break it by accident.

Four facts from the current baseline set the limits:

1. **The Pi default route must stay on wlan0.** The bring-up notes give the
   lab link no gateway on purpose. `reprovision.sh` refuses to wipe when the
   default route is via the lab link.
2. **The hEX drops new forwarded connections from ether1.** ether1 is in the
   `WAN` list, and `default-config.rsc` drops new connections from `WAN` that
   are not DSTNATed. If the Pi sends its internet traffic through the hEX,
   the hEX drops it.
3. **The hEX input chain drops everything that is not from `LAN`.** ether1
   is not in `LAN`. So OSPF and BGP from the Pi need their own accepts.
4. **The hEX learns its own default route from DHCP on ether5**
   ([decisions/009](009-wireguard-endpoint-and-uplink.md)).

Three questions were open: OSPF or static routes, which BGP session type,
and which box originates the default route.

## Decision

**1. OSPF, not static routes, for the link and the loopbacks.**

Each box gets a `/32` router ID on its loopback: `10.255.0.1` on the hEX,
`10.255.0.2` on the Pi. OSPF area 0 runs on the ether1 link as
point-to-point. The hEX also advertises the lab LAN `192.168.88.0/24` as a
passive interface.

The reason is the purpose of the lab. Static routes would give the same
reachability with fewer parts. But a static route cannot show an adjacency
form, fail, and recover, and item 4 needs a routing protocol that it can
break and observe. OSPF is the standard IGP for this job, and both FRR and
RouterOS implement it natively.

**2. eBGP on the link addresses, with private ASNs, not iBGP between
loopbacks.**

The hEX is AS 65001, and the Pi is AS 65002 (RFC 6996 private range). The
session runs between `192.168.99.1` and `192.168.99.2`. The Pi announces one
service prefix, `10.255.1.1/32`. The hEX announces nothing.

The Pi opens the session, and the hEX only listens. So the Pi has no BGP
listener on wlan0.

Reasons:

- **Independent failure.** eBGP on the link does not depend on OSPF. When
  one protocol fails, the other stays up, and the failure has one cause.
  iBGP between loopbacks depends on OSPF to reach the loopbacks, so an OSPF
  failure also takes BGP down.
- **The backlog.** "k8s as a CNI/BGP networking lab" is on the backlog. A
  cluster on the Pi (for example, MetalLB or Calico) peers with the router
  in eBGP from a private ASN and announces service prefixes. This session has
  that shape now, so the router side does not change later.
- **Explicit policy.** eBGP in FRR requires import and export policy. The
  config must state what each side sends and accepts.

**3. No box originates a default route.**

The hEX does not originate a default route into OSPF, and it sends no BGP
routes. The Pi does not originate one either. The Pi default route stays on
wlan0. The hEX default route stays on the ether5 DHCP client.

This follows from facts 1, 2, and 4. A default route from the hEX would move
the Pi's traffic onto the lab link, where the forward drop discards it, and
the `reprovision.sh` preflight would then refuse to run. A default route
from the Pi has no purpose, because the Pi is not an uplink.

**4. Each side accepts only an allow-list of prefixes.**

- The Pi installs into the kernel only `10.255.0.0/16` host routes and
  `192.168.88.0/24`. Everything else from OSPF or BGP stays out of the
  kernel. This is the self-lockout guard. It stops a default route and a
  route to the house LAN, even if the hEX side changes.
- The hEX accepts only `10.255.0.0/16` host routes from OSPF and only
  `10.255.1.0/24` host routes from BGP.

An allow-list fails closed. A deny-list fails open for any prefix that
nobody thought of.

**5. The hEX gets two narrow input accepts, and nothing wider.**

OSPF (IP protocol 89) and BGP (TCP 179), each only from `192.168.99.2` on
ether1, above the `!LAN` drop. This follows the shape of the SSH accept in
[decisions/006](006-management-surface-on-ether1.md). That ADR said that a
wider management surface must be a deliberate change. This is that change,
and it is recorded here.

**6. The router side is applied after provisioning, not in
`default-config.rsc`.**

`default-config.rsc` is the baseline that every wipe returns to, and item 4
needs that baseline small. So the hEX side of OSPF and BGP is a separate
script that the owner applies, like the WireGuard keys in
[decisions/009](009-wireguard-endpoint-and-uplink.md).

**7. The Pi stays a host.** FRR does not turn on IP forwarding. With
forwarding on, the Pi would route between the house LAN and the lab.

Where the decision lives:

| Piece | File |
|---|---|
| Pi daemons | `frr/daemons` |
| Pi OSPF, BGP, and route guard | `frr/frr.conf` |
| hEX side, apply and remove | `provisioning/frr-router.rsc`, `provisioning/frr-router-remove.rsc` |
| Pi install with route guard | `provisioning/frr-install.sh` |
| Pi check | `provisioning/frr-verify.sh` |
| Run sheet and rollback | `docs/frr-bringup.md` |

## Consequences

**What this gives:** a routing protocol pair that item 4 can break in
distinct ways. A failed OSPF adjacency, a failed BGP session, and a
filtered prefix each show a different symptom. The management SSH path
does not depend on either protocol, because it uses the connected `/30`.

**What this costs:**

- The management surface on ether1 is wider by two accepts. Each is limited
  to one source address and one protocol.
- A wipe removes the hEX side. The owner applies it again after each wipe
  until a later decision adds it to `reprovision.sh`.
- The lab LAN route reaches the Pi, but the forward drop still blocks new
  connections from the Pi to hosts on the lab LAN. The Pi can ping only the
  router's own addresses. This is the existing forward policy, not a fault.
- No authentication on OSPF or BGP. The link is a physical `/30` with two
  hosts, so no third party can join it. Authentication would put a secret on
  the provisioning path, and this repo is public.
- `10.255.0.0/16` is now lab address space. The WireGuard client
  `AllowedIPs` does not include it, so a remote client cannot reach the
  loopbacks until someone adds it.

**What this forecloses:** nothing permanently. iBGP, a default route, or a
wider allow-list is each a change in one or two files.

## Alternatives Considered

| Option | Reason Not Chosen |
|--------|-------------------|
| Static routes only | Fewer parts, same reachability. But nothing forms or fails, and item 4 needs a protocol it can break and observe |
| iBGP between loopbacks, OSPF as the underlay | The textbook ISP pattern, and it teaches next-hop resolution. But BGP then fails when OSPF fails, which hides the cause. It also does not match the eBGP shape that a future k8s peer uses |
| OSPF only, no BGP | Meets half of item 3. It gives nothing to the k8s backlog item, which is a BGP use |
| BGP only, no OSPF | Meets half of item 3, and loses the IGP adjacency that item 4 can observe |
| The hEX originates a default route to the Pi | Moves the Pi traffic onto the lab link, where the forward drop discards it. It also trips the `reprovision.sh` preflight |
| OSPF and BGP in `default-config.rsc` | Survives a wipe, but it makes the baseline larger, and item 4 wants the baseline small. An error in a new routing line could also stop the script before the arming line at the end |
| Accept all OSPF and BGP on ether1, with no source match | One rule, but wider than needed, and it breaks the narrow pattern that decisions/006 set |
| A deny-list for the default route, not an allow-list | Stops the one known risk. It fails open for a house-LAN prefix or any other prefix that nobody listed |
| MD5 or TCP-MD5 authentication | Puts a secret on the provisioning path of a public repo. The physical `/30` has no third host to guard against |
