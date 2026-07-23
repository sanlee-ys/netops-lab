# 004 — Research standing of the agent experiment: what's claimable and what isn't

Status: Accepted

## Context

This lab has two goals: ZTP closure (a build) and the self-lockout agent
experiment (potentially a contribution). Before committing build time to the
second, a literature check ran — 26 agents, findings verified against full
PDFs rather than abstracts, adversarially reviewed so that "this ground is
taken" had to survive a refutation attempt.

The check was worth running because the surrounding subfield went from sparse
to crowded inside a year. A prior search four months earlier had found the
self-lockout ground open; the question was whether that still held.

## Decision

Three limbs were checked. Their verdicts set what this lab may claim.

**1. Agent trust-establishment during bootstrap — DEAD, and closed by
construction rather than merely occupied.**

RFC 8572 (Secure ZTP) and RFC 8995 (BRSKI) settle "who do I trust at first
boot" with normative MUSTs: manufacturer trust anchors validate an RFC 8366
voucher, the pinned domain cert validates the owner. No judgment is left for
an agent to exercise. Building an agent that decides bootstrap trust would
reinvent a solved standard badly.

**This verdict does not touch ZTP as a build.** The lab's first deliverable
is closure and competence, not novelty. Do not re-apply a publishability bar
to it.

**2. Self-lockout — OPEN.** Cleared at full-PDF level:

- arXiv 2606.06212 (Agentic Configuration Repair, Jun 2026) — Batfish-style
  verification, no lockout scenario, no commit-confirm
- arXiv 2605.12729 (LLMs for Agentic NetOps, Jun 2026) — has rollback, but
  keyed to failure/regression, never to loss of contact
- NetAgentBench (arXiv 2604.09678) — no management-access dimension,
  confirmed in the text rather than merely unmentioned
- NetConfBench (draft-cui-nmrg-llm-benchmark-02, Jul 2026) — no rollback, no
  management-plane check

Commit-confirmed exists as vendor practice (JunOS, IOS XE `configure
replace`) and as patent US 11888695, but has never been lifted into
agent-runtime semantics.

**3. The unified "establish then preserve capacity to act" seam —
REPOSITION.** Unclaimed, but half of it sits on standards-occupied ground.
The narrower survivor: *the agent's control path is a resource it can spend,
and no existing safety machinery meters it.* Corrigibility work is opposite
polarity — it preserves the human's leverage and treats agent capability as
the hazard.

## Consequences

**The claimable contribution, stated flatly:** commit-confirmed /
rollback-on-loss-of-contact as agent-runtime safe-commit semantics, plus the
first measurement of how often agents sever their own management plane.

**Cite, don't compete:** RFC 8572/8995 as settled trust substrate.
NetAgentBench and NetConfBench as the config-correctness baseline this is
orthogonal to — related work, not rivals. draft-cui-nmrg-llm-nm-02's
NACM/audit model as the governance layer beneath. JunOS commit-confirmed as
the mechanism being *moved, not invented* — say so plainly, or a reviewer who
knows JunOS kills it in one line.

**The detector has to be validated before the rate means anything.** The
headline number is "how often do agents sever their own management plane",
which is only as trustworthy as the thing deciding whether a severing
happened. A detector that quietly never fires produces a beautiful 0% and
says nothing.

So before measuring anything: build a small set of configs known to sever the
management path — drop the management-interface address, an ACL that blocks
the agent host, a firewall rule ordered above the accept, a bad default route
— and assert the detector flags each one for the right reason. Only then run
the population you actually care about.

This is the injected-defect / mutation-testing pattern, and it is prior art
rather than novelty: classical mutation testing dates to DeMillo 1978, and
FBI (EMNLP 2024) applied targeted perturbations to LLM judges specifically.
Cite it as method, do not claim it.

Note the asymmetry, because it decides which way to tune: a detector that
*misses* a lockout costs one lost data point. A detector that *falsely
reports* one corrupts every measurement built on it and sends you chasing a
severing that never happened. Injected defects only measure sensitivity —
every case severs by construction — so a clean control arm of configs that
change the device *without* severing is required to say anything about false
alarms.

**Experiments:**

- **Baseline lockout rate — survives, and is the whole paper.** No benchmark
  measures this. Gated on the detector validation above.
- **Safe-mode primitive — survives**, but must be framed as agent-runtime
  semantics rather than networking novelty. RouterOS `netwatch` already ships
  the mechanism, which sharpens the question from "invent it" to "does the
  agent know to use it."
- **Does-provisioning-carry-forward — cut.** It depended on limb 1.

## Alternatives Considered

**Building the bootstrap-trust agent anyway** — rejected. The standards close
it by construction; there is no ambiguity left for an agent to resolve.

**Leading with "a network is a verifiable environment giving free ground
truth, unlike text tasks needing LLM judges"** — rejected as a *lead*. True,
and it stays as design rationale, but NetAgentBench got there first with
deterministic property satisfaction over final device state. Adopt and cite
it; don't compete with it.

## Open — close before writing any research writeup

1. **NetPress (arXiv 2506.03231) advertises a "safety" metric** that neither
   the abstract nor the README defines, and whose PDF would not extract. The
   most plausible hiding place for a self-lockout notion. Read the metric
   code in `Froot-NetSys/NetPress`. Note NetPress and NetArena are the *same
   paper retitled*.
2. **Distributed-systems fencing / split-brain was never swept** — the
   likeliest place this exists under other vocabulary (fencing tokens,
   STONITH, lease expiry). An agent losing its control channel and a node
   losing quorum are structurally the same problem. This is the classic way a
   novelty check fails: search your own field thoroughly, miss the
   neighbouring one that named it differently.

Also unswept: NANOG/RIPE, USENIX LISA/SREcon, HotNets, IETF NETMOD/NETCONF;
no paywalled full-text (ACM DL, IEEE Xplore, NDSS); IEEE 802.1AR verified at
scope-statement level only; RFC 8366 not fetched.

Phrase any novelty claim as "no published treatment found", never "nobody has
done this".
