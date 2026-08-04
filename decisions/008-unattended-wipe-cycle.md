# ADR-008: The wipe cycle runs unattended — one command, no physical action

**Status:** Accepted
**Date:** 2026-08-03
**Deciders:** San Lee

## Context

[decisions/005](005-pi-as-ztp-host.md) set out to make a wipe cycle "one
command on the Pi followed by a power cycle." That was as far as it could go at
the time, for a reason that turned out to be wrong: the power cycle was assumed
to be the thing that put the board into Etherboot.

Three findings on 2026-08-03 removed every barrier to closing the gap. All are
measured on the board rather than reasoned from documentation, and the method is
in `docs/bring-up-notes.md`.

**RouterBOOT runs its `boot-device` logic on every boot.** A soft
`/system reboot` issued over SSH reaches Etherboot exactly as a power cut does.
The plug was never the trigger; any boot is. It also returns cleanly over a
non-interactive SSH with no confirmation prompt — the same interactive-only
pattern as RouterOS's forced first-login password change.

**The arm is a one-shot.** `try-ethernet-once-then-nand` is consumed by the
next boot, server listening or not, and RouterBOOT then reverts the stored value
to its default. ADR-005's arming happens at provision time and therefore covers
exactly one boot. This is not a detail: the board was found sitting unarmed at
the start of this session, meaning ADR-005's documented cycle would not have
worked at that moment.

**The provisioning script's arming line does run.** That question is closed, so
provision-time arming is a real mechanism rather than a suspected one — it is
simply narrower than ADR-005 claimed.

What remained was a design question rather than a technical one: whether to
remove the last human action from a destructive operation.

## Decision

**1. `reprovision.sh` drives the entire cycle.** It arms the board over SSH,
starts the Netinstall server, waits until that server is genuinely listening,
reboots the router into it over SSH, waits for the install, and verifies the
result. One command, no physical action.

**2. There is no confirmation prompt.** This is the substantive decision and it
is made knowingly: the power cycle it replaces was functioning as an accidental
confirmation step, and removing it means one command now wipes hardware with no
second human action.

Accepted because the protection this cycle actually relies on is the
default-route preflight — the check that refuses to wipe the router you are
reached through — and not the accident of someone walking to a plug. A
confirmation prompt would also defeat the purpose: an unattended cycle that
stops to ask is attended. The whole premise of ADR-005 is that wipes stop being
events, because a wipe that takes ceremony is a wipe that stops getting run.

**The consequence is recorded rather than mitigated: the default-route preflight
is now load-bearing in a way it was not before.** It should not be weakened, and
it is the first thing to check if this script ever does something surprising.

**3. Readiness is measured by the socket, not by the log.** The server must be
listening before the reboot is issued; reversing that order spends the arm and
leaves the cycle worse off than when it started, needing a re-arm before it can
be retried. So the gate is a poll for a listener on `udp/67`.

Matching the vendor's log text was the obvious alternative and is worse twice
over. It ties the cycle to one build's wording, and `netinstall-cli` is a
statically linked binary under user-mode QEMU whose stdout is block-buffered
into a file — `stdbuf` cannot fix that, because it works by `LD_PRELOAD` and a
static binary ignores it. The obvious workaround is unavailable, and the socket
is a better question to ask regardless: it tests the thing that matters instead
of inferring it.

**4. An unreachable router is a branch, not an error.** If SSH fails, the
script starts the server and asks for a power cycle instead of aborting. A
locked-out or factory board cannot be armed or rebooted over a management path
that is already broken, and that is precisely the case Netinstall exists for.
Refusing to run there would withhold the tool at the only moment it is
irreplaceable.

Deliberately *not* a preflight gate on "is the board armed." That check would
be correct for routine cycles and actively harmful for recovery ones.

**5. Everything unattended gets a timeout.** Server readiness, the install
itself, and post-install verification. Attended, a hang looked like slowness and
a human eventually gave up; unattended, nobody is watching. The install timeout
in particular names its likeliest cause — a board that was not armed at the
moment it rebooted.

**6. The script verifies its own result.** One non-interactive SSH exercises
addressing, the management accept landing above the `!LAN` drop, the key import
having run inside a first-boot script, and password login being off. It also
checks whether the board came back re-armed.

This closes a gap the previous version named honestly and could not fix: a run
marked `ok` in the log used to mean the install ran and nothing more. It now
means the install ran *and* the router answered a non-interactive SSH.

Two distinctions in the log are deliberate, because collapsing them would make
the number it produces less honest rather than more. Whether the board came back
re-armed is a **separate field**, not part of `ok` — an unarmed board is a
degraded success, and its likeliest cause is a genuinely factory board whose
device-mode blocks the arming line, which is a case this script is meant to
support. And when the Pi's `ssh-agent` is empty, verification is recorded as
**skipped** (`"ok":null`) rather than failed: every SSH here uses `BatchMode`,
so it cannot run at all, and marking a good wipe bad would put a false negative
into the one log meant to measure repeatability. That combination is routine
rather than exotic — decisions/006 accepts that the agent needs a human after
every Pi reboot, and a power event takes the Pi and the router down together.

Firewall *rule order* is still checked by hand, and the script still
says so.

## Consequences

**What this buys:** roadmap item 1's original goal, met rather than approximated
— a factory-blank-to-configured cycle with nothing physical in it. Repeat cycles
become cheap enough to be boring, which is the property item 4 needs. And the
run log becomes trustworthy as a measure of the cycle rather than of one tool's
exit status.

**What this costs:** one command wipes hardware with no confirmation. The
default-route preflight carries that safety alone. There is also more machinery
than before — a backgrounded root process, a readiness poll, three timeouts, and
a cleanup path — and machinery is surface to get subtly wrong. The `known_hosts`
handling in particular is order-dependent in a way that is easy to break: the
file is cleared twice, once so pre-wipe SSH can connect through a stale entry
and once after the reboot because the board's identity is about to change.

**What this forecloses:** nothing permanently. A confirmation prompt is a
one-line addition if the blast radius ever stops feeling acceptable, and the
manual path still exists — it is what the unreachable branch does.

## Deferred

- **Remote power control.** Still the only thing that would make the
  *unreachable* branch unattended too, and still new hardware under
  [decisions/001](001-hardware-substrate-scope.md). It is now the single
  remaining physical action in the whole lab, which sharpens the case but does
  not by itself justify the purchase. Revisit when item 4 wants trial volume.
- **The factory-board first cycle.** Unchanged and still needs the reset-button
  hold plus a one-time device-mode update, because a factory board ships with
  `routerboard: no` and cannot be armed at all. Netinstall 7.22's `-sm` can set
  device-mode directly; that remains the upgrade's only real draw.
- **The Pi's `ssh-agent` after a reboot.** [decisions/006](006-management-surface-on-ether1.md)
  accepted that a human unlocks it, and this ADR does not revisit it. It is now
  the only remaining human step in the routine cycle, and it is the one this
  script warns about at preflight rather than failing on.

## Alternatives Considered

| Option | Reason Not Chosen |
|--------|-------------------|
| Keep the power cycle as an implicit confirmation | Preserves a human gate on a destructive action, but it is a gate by accident rather than by design, and it blocks the unattended repeat cycles item 4 depends on. The real protection is the default-route check |
| Confirmation prompt, with a `--yes` flag for automation | Looks like the safe compromise and is mostly theatre: the automation path skips it, so the flag becomes the normal invocation and the prompt protects only the case that was already careful |
| Arm only, and leave the reboot to a human | Half the change for most of the risk — still no confirmation on the wipe itself, still needs someone present. Removes the benefit without removing the hazard |
| Wait for `Waiting for RouterBOARD` in the tool's output | Ties the cycle to one build's log wording, and the output is block-buffered through a file with no way to unbuffer a static binary under QEMU. The socket answers the real question |
| A fixed `sleep` before rebooting | Trivially simple and silently wrong on a slow start: the board Etherboots into nothing, spends the arm, and reverts — the exact failure the ordering exists to prevent |
| Preflight-gate on the board being armed | Correct for routine cycles, harmful for recovery ones. An unreachable board cannot be armed, and that is when Netinstall matters most |
