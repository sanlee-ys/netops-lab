# CLAUDE.md — netops-lab

## Project

A personal MikroTik + Raspberry Pi home lab. Two goals, strictly sequenced:
(1) get San real, hands-on ZTP (zero-touch provisioning) experience on
hardware he owns; (2) once ZTP is proven, use the same rig as the substrate
for a self-lockout agent experiment (can an agent operating on a live router
avoid locking itself out — RouterOS's built-in `netwatch` facility is the
mechanism in question). Full context: `README.md` and `decisions/`.

## Scope discipline

This is a lab, not a framework. Build the seam — provision one device, make
one change that can sever it — not an end-to-end network lifecycle. See
[decisions/001](decisions/001-hardware-substrate-scope.md) for what's
explicitly out of scope, and don't re-add it without a new ADR.

Sequencing is load-bearing: ZTP + Netinstall recovery must work *before* an
agent is let near the device. A reliable wipe-to-provisioned cycle is the
experimental harness that makes lockout runs repeatable rather than a manual
rebuild each time.

## How to work with me

- This is design/learning work, not a bounded execution task — work in
  small steps, explain the key decision at each one, and wait before moving
  to the next. Don't chain hardware or config changes without a checkpoint.
- When there's a real design choice (RouterOS config structure, how the
  agent talks to the router, what the self-lockout experiment measures),
  surface it and ask rather than silently picking.
- San drives the physical bring-up himself (console access, cabling,
  power-cycling, Netinstall) — hand back the command or the step, don't
  attempt to perform physical actions.
- Explain the *why* behind RouterOS/networking decisions, not just the
  *what* — this lab is as much about San relearning networking fundamentals
  as it is about the artifact.

## Links — verify before sending (hard rule)

Links given in chat must resolve: **full
`github.com/<owner>/<repo>/blob/<ref>/<path>` URLs only**, **verify the path
exists on the ref before sending** (unverified → say so), and **branch links
are perishable** (prefer `main` once merged). Full rule + rationale:
[claude-ops `conventions/links-verify.md`](https://github.com/sanlee-ys/claude-ops/blob/main/conventions/links-verify.md).
