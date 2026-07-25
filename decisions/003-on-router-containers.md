# ADR-003: On-router containers — possible on this board, still not used

**Status:** Accepted
**Date:** 2026-07-21
**Corrected:** 2026-07-25 — the original version of this ADR reasoned about the
wrong board. See "Correction" below.
**Deciders:** San Lee

## Correction (2026-07-25)

This ADR was written 2026-07-21 and concluded the router was
**container-incapable, permanently**, on the basis that it was an RB750Gr3
(MMIPS, 16MB flash). The router actually purchased on 2026-07-22 is the
**hEX refresh, E50UG** — a different board, swapped in during checkout purely
on delivery timing.

The original text even named this board as the search-results trap to watch
for: *"MikroTik sells a similarly-named hEX Refresh (EN7562CT) that **is**
container-capable at arm32v5."* The caution was right; the purchase then
landed on that exact model and the ADR was never revisited.

The **decision** below survives unchanged. The **reason** does not: on-router
containers went from impossible to merely unused.

## Context

RouterOS 7 ships a Container package. The question is whether this lab's
router can run it, and whether it should.

The board in this lab is the **hEX refresh (E50UG)**, per its product page:

| | Value |
|---|---|
| CPU | EN7562CT, **ARM 32-bit**, 2 cores @ 950 MHz |
| RAM | 512 MB |
| Storage | 128 MB NAND |
| Other | 5× Gigabit ethernet, 1× USB Type-A, passive PoE in |

MikroTik's Container docs list supported architectures as **arm, arm64, x86**.
ARM 32-bit qualifies, so the Container package is installable on this board —
unlike the RB750Gr3 (MMIPS), which it never would have been.

Two practical limits remain. 128 MB of NAND is not much room for images, and
MikroTik's own docs push container storage to external media even on boards
that do support containers. The E50UG has a USB port, so external storage is
available if wanted.

**Not tested on hardware.** This is reasoned from vendor documentation; the
router lands 2026-07-25. Treat "installable" as expected, not verified.

## Decision

**All container workloads for this lab run on the Pi, never the router** —
unchanged from the original ADR.

What changed is the standing of that decision: it is now a **choice**, not a
constraint. On-router containers are possible and deliberately unused.

The reasons that survive the correction:

- Nothing in this lab's scope needs them. The capability inventory (DHCP,
  packet capture, firewall/NAT, RouterOS API scripting, netwatch, remote
  syslog) is all native RouterOS.
- [decisions/002](002-keep-the-hex-decline-rb5009.md)'s topology argument is
  untouched and is the stronger one: the Pi is the dual-homed *agent host*,
  and running the agent's own workload on-router would break the lockout
  observation this lab is built around.
- 128 MB of NAND makes the router a poor container host regardless of whether
  it is a legal one.

The reason that does **not** survive: "architecture mismatch makes it a
guaranteed failure." That was true of the RB750Gr3 and is false here.

## Consequences

**What this buys:** the same clear split as before — containers live on the
Pi — without resting it on a false premise a future session would eventually
trip over.

**What this changes:** on-router containers become a real option if a
specific need ever names them, rather than a closed door. Small, native-ish
workloads (a DNS-level adblocker, a lightweight always-on service) are within
reach on 512 MB of RAM with USB storage.

**What this forecloses:** nothing. The lab's container work was never going to
live on the router for topology reasons that still hold.

**Knock-on:** [decisions/002](002-keep-the-hex-decline-rb5009.md) partly
justified keeping the hEX over the RB5009 on the grounds that the hEX could
not run containers anyway. That leg is gone — this board can. The conclusion
stands on its remaining reasons (the Pi runs FRR better and on the substrate
the benchmarks use; the cheap router is the one worth bricking).

## Alternatives Considered

| Option | Reason Not Chosen |
|--------|-------------------|
| Run this lab's container workloads on the router | Possible on this board, but the Pi is the agent host by design, and 128 MB NAND makes the router a cramped host even with USB storage |
| Leave the original ADR as written | It is factually wrong about the hardware in hand, and its "verified, not assumed" framing made it *more* likely to be trusted uncorrected |
| Supersede with a new ADR | The decision did not change — only its justification. A correction in place keeps one file as the answer instead of two |
