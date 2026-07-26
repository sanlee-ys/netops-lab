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

- This is design/learning work, not a bounded execution task. **Checkpoint
  before anything that touches the router or the Pi** — config changes,
  provisioning steps, anything that could sever access — and explain the key
  decision at that step rather than after it. Never chain two of those
  together. Ordinary repo work (docs, ADRs, scripts that don't run against
  hardware) doesn't need a checkpoint per step; do the batch and report.
- When there's a real design choice (RouterOS config structure, how the
  agent talks to the router, what the self-lockout experiment measures),
  surface it and ask rather than silently picking.
- San drives the physical bring-up himself (console access, cabling,
  power-cycling, Netinstall) — hand back the command or the step, don't
  attempt to perform physical actions.
- Explain the *why* behind RouterOS/networking decisions, not just the
  *what* — this lab is as much about San relearning networking fundamentals
  as it is about the artifact.

## Machines

Three surfaces touch this repo and none of them can see the others' state, so
the split is recorded here rather than re-derived every session:

- **The PC commits.** It holds the git identity, SSH commit signing, and `gh`.
  Anything that ends in a branch and a PR happens there.
- **The Pi touches hardware** — Netinstall, the router, the wipe cycle, per
  [decisions/005](decisions/005-pi-as-ztp-host.md) — and hosts long-running
  detached agent sessions under `herdr`.
- **The Pi deliberately has no git identity.** It is not configured to commit,
  and that is the design rather than an oversight: work done there is reported
  back and committed from the PC. Don't "fix" it by setting `user.email` on the
  Pi. That would hand an agent path with no audit trail the ability to write
  history.

`herdr` on the Pi is used for session persistence only. Its `done` state and its
`agent prompt` call are not dependable — see claude-ops
[ADR-005](https://github.com/sanlee-ys/claude-ops/blob/main/decisions/ADR-005-herdr-persistence-not-agent-awareness.md).

<!-- shared:links-verify v1 -->
## Links — verify before sending (hard rule)

Links given in chat must resolve: **full `github.com/<owner>/<repo>/blob/<ref>/<path>` URLs only**, **verify the path exists on the ref before sending** (unverified → say so), and **branch links are perishable** (prefer `main` once merged). Full rule + rationale: [claude-ops `conventions/links-verify.md`](https://github.com/sanlee-ys/claude-ops/blob/main/conventions/links-verify.md).
<!-- /shared:links-verify -->
