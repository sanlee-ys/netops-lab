# ADR-002: Keep the hEX, decline the RB5009 upgrade

**Status:** Accepted
**Date:** 2026-07-21
**Deciders:** San Lee

## Context

Mid-purchase, cancelling the cheap MikroTik hEX in favor of the RB5009
(~$220 vs ~$67) was considered. The RB5009 is a genuinely more capable
router — notably, it can run RouterOS containers natively (arm64), which at
the time was believed to be something the hEX could not do.

**That premise turned out to be false** — the board actually bought (hEX
refresh, E50UG) is ARM and can run containers, just with far less storage.
See [decisions/003](003-on-router-containers.md). The conclusion below
does not depend on it; the reasons that carry it are the Pi running FRR
better and the topology argument.

## Decision

Keep the hEX. Do not upgrade.

The only real capability the RB5009 buys over the hEX-plus-Pi combination is
FRR-on-router. The 8GB Pi already runs FRR better — on the same
FRR-on-Linux substrate that networking-agent benchmarks (e.g.
NetAgentBench-class evals) actually use, so it doubles as practice for that
substrate rather than a router-specific dead end. Nothing in the ZTP goal or
the rest of the capability inventory (DHCP, packet capture, firewall/NAT,
RouterOS API scripting, netwatch, remote syslog) needs containers on the
router.

There's also a topology reason the RB5009's container support couldn't be
used even if bought: the Pi is the dual-homed *agent host* in this lab's
design. Running the agent's own workload on-router would break the lockout
observation this lab is built around — the whole point is that the agent's
host survives a lab-segment outage it may cause.

The cheap router is a feature, not just a cost saving: it's the device
this lab is willing to let an agent brick.

## Consequences

**What this buys:** ~$150 saved, redirected to nothing in particular — it
just wasn't spent. A router that's genuinely disposable for the lockout
experiment.

**What this forecloses:** the RB5009's throughput and its headroom for
on-router workloads — not container support as such, which this board turned
out to have. If FRR-on-router or
another RB5009-only capability is ever actually wanted, the answer is to buy
one *later* as a second device — a two-router lab is more valuable here than
one better router, since it also unlocks router-to-router scenarios
(peering, redundancy) the single-router lab can't test at all.

## Alternatives Considered

| Option | Reason Not Chosen |
|--------|-------------------|
| Upgrade to RB5009 | Its assumed edge (on-router containers) isn't one — the hEX refresh runs them too. Its real edge, headroom for on-router workloads, conflicts with the Pi's role as agent host |
| Buy both now | No capability currently needs it; buy the second router only when a specific router-to-router scenario names the need |
