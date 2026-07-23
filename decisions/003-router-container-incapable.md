# ADR-003: The router is container-incapable by design — verified, not assumed

**Status:** Accepted
**Date:** 2026-07-21
**Deciders:** San Lee

## Context

RouterOS 7 ships a Container package. Before ruling containers out on the
hEX, this was checked directly rather than assumed either way — search
results for "hEX + containers" are misleading, because MikroTik sells a
similarly-named *hEX Refresh* (a different board, EN7562CT) that **is**
container-capable at arm32v5.

## Decision

Treat the router as container-incapable, permanently, for this lab's
hardware:

- MikroTik's own Container docs (help.mikrotik.com) list supported
  architectures as **arm, arm64, x86 only** — no MIPS.
- The router in this lab is **MMIPS** (MT7621A), per its product page.
- It also has only **16MB of flash**, which would disqualify container use
  independently even on a supported architecture — MikroTik's own docs push
  container storage to external media even on boards that do support it.

All container workloads (FRR, syslog viewer, any future agent runtime) run
on the Pi. This is not a workaround — see
[decisions/002](002-keep-the-hex-decline-rb5009.md) for why on-router
containers were never the goal here in the first place.

## Consequences

**What this buys:** no time spent chasing a Container package install that
was never going to work on this specific board, and a documented reason not
to re-investigate it if a future upgrade is ever considered.

**What this forecloses:** nothing this lab needs — container support was
never load-bearing for the ZTP or self-lockout goals.

## Alternatives Considered

| Option | Reason Not Chosen |
|--------|-------------------|
| Try installing the Container package anyway | Architecture mismatch (MMIPS) makes it a guaranteed failure, not a risk worth testing |
| Buy the hEX *Refresh* instead of the plain hEX | Different board; would've required re-sourcing after the plain hEX was already in the cart, for a capability this lab doesn't use ([decisions/002](002-keep-the-hex-decline-rb5009.md)) |
