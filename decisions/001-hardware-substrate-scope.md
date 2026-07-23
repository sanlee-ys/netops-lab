# ADR-001: Hardware substrate, not a simulator — and what's explicitly out of scope

**Status:** Accepted
**Date:** 2026-07-21
**Deciders:** San Lee

## Context

A labeled ZTP + self-lockout lab needs some substrate to run on. Options:

1. **containerlab** — free, runs on the desktop, scales to many virtual nodes.
2. **Real hardware** — a physical MikroTik router + a physical host, bounded
   to whatever topology fits on a desk.
3. **Mix** — hardware for the parts that need it, containerlab for volume.

The literature check that motivated this lab recommended containerlab for
building a *measured-lockout-rate research artifact* — many repeated trials
at low marginal cost. That recommendation answers a research-scale question
this lab isn't asking. The actual driver is narrower: get real hands-on ZTP
experience on hardware, and use the result as the substrate for one
repeatable agent experiment — not a statistical study.

## Decision

Build on real hardware — one MikroTik router, one Raspberry Pi. Reuse
containerlab later, on the desktop, only if a volume-of-topologies need
actually shows up (e.g. a k8s CNI/BGP peering lab); it stays a bolt-on, not
the primary substrate.

Scope is deliberately narrow: build the *seam* (provision one device, then
make one change that can sever it), not an end-to-end network lifecycle.
Concretely, out of scope unless a later decision picks it up:

- A second router or switch, a rack, a PDU, a monitor/keyboard for the Pi
  (it runs headless).
- RouterOS containers on the router itself — see
  [decisions/003](003-router-container-incapable.md) (router is MMIPS +
  16MB flash, containers are arm/arm64/x86 only per MikroTik's own docs).
- Kubernetes, beyond a possible future single scenario (k8s as a CNI/BGP
  networking lab where a cluster and the router actually talk to each
  other) — a single-node control plane to debug on top of the networking
  already under debug is ceremony that teaches nothing new.

## Consequences

**What this buys:** the lab witnesses out-of-band access, bare-metal
bring-up, and management-plane behavior a simulator abstracts away — the
part that's hardest to get right without hands-on practice.

**What this costs:** trial volume. One physical router means one lockout
recovery cycle at a time (via Netinstall), not hundreds of parallel runs. If
a statistical lockout-rate claim is ever wanted, that's a *different*,
explicitly-scoped follow-on, not this lab.

**What this forecloses:** exotic multi-node topologies. Extra physical
hardware only gets bought when a specific experiment needs a *physical*
node on a *real* segment — never speculatively.

## Alternatives Considered

| Option | Reason Not Chosen |
|--------|-------------------|
| containerlab only | Can't witness out-of-band / management-VRF behavior; answers a research-volume question this lab isn't asking |
| Full mixed hardware+containerlab build up front | Premature — containerlab has no job yet; add it only when a real volume need appears |
