# ADR-007: Herdr is the agent workspace on the Pi — for persistence, not for driving

**Status:** Accepted
**Date:** 2026-07-26
**Deciders:** San Lee
**Related:** claude-ops
[ADR-005](https://github.com/sanlee-ys/claude-ops/blob/main/decisions/ADR-005-herdr-persistence-not-agent-awareness.md)
holds the general, cross-repo version of this decision — what the trial means
for running long agent sessions anywhere. This ADR is the lab's application of
it: what it means for a box that provisions routers. The two were written in
parallel by two sessions that could not see each other, which is itself recorded
in claude-ops
[ADR-006](https://github.com/sanlee-ys/claude-ops/blob/main/decisions/ADR-006-claim-the-concern-before-working-it.md).
Keep them in sync: a finding that changes the general rule changes this one.

## Context

[decisions/005](005-pi-as-ztp-host.md) names the Pi as "the always-on,
wifi-reachable box that later hosts the agent." Roadmap item 4 — the
netwatch-driven self-lockout experiment — will run an agent against a live
router for long, repeatable sessions. What that agent *runs inside* is therefore
on item 4's critical path, and had never been decided.

Herdr is a terminal workspace manager built specifically for AI coding agents.
Its claim over plain `tmux` is agent awareness: it reports whether each pane's
agent is working, idle, blocked, or done, and exposes that over a socket API. If
that works, a wipe-and-provision loop could be driven and observed
programmatically. That claim was tested on hardware rather than argued about.

**Why the Pi and not the PC.** Herdr publishes stable builds only for Linux and
macOS; Windows appears on preview releases only, and `herdr channel set stable`
is rejected there. The Windows beta also breaks direct terminal attach, remote
mode and foreground process groups, with known Shift+Enter and PowerShell
cwd-tracking problems that would land on Claude Code specifically. The Pi gets
the stable aarch64 build, and ADR-005 already put the agent there.

**Tested on hardware 2026-07-26**, herdr 0.7.5 against Claude Code 2.1.220. A
subject agent ran inside a pane; a second agent ran outside it, polling the
socket API every 2 seconds and reading herdr's own server log. The observer had
to be outside, because a session inside the pane goes blind during exactly the
window worth measuring.

**Persistence holds.** The server daemonizes to PPID 1 with no controlling
terminal, and the pane's agent runs on herdr's own pty. Killing the SSH
connection that launched it left both alive with scrollback intact — which
matters on a box reached over wifi, where the link is the least reliable part.

**Awareness works, and is not built the way the documentation implies.** Every
state herdr reported was correct, attached and detached, including the subtle
case of a pane holding *unsubmitted* text in its prompt box — visually busy,
correctly reported idle. With no client attached it tracked a full cycle:

```
10:48:08  client disconnected (no reconnect)
10:54:03  ->  working
10:54:19  ->  idle
```

But the mechanism is entirely screen-scraping. The winning rule regexes a
braille spinner out of the OSC terminal title (`^[\x{2800}-\x{28FF}] `); others
match literal UI strings such as `esc to interrupt` and
`do you want to proceed?`. The integration hook contributes **no state at all**
— it only calls `pane.report_agent_session`, mapping a pane to a session ID.
Pushing an explicit state via `pane.report_agent`, using the official
`herdr:claude` source and a fresh sequence number, was ignored. The screen
manifest is the sole authority, and nothing Claude Code reports can override it.

**Two capabilities do not work.**

`herdr agent prompt` delivers keystrokes into the prompt box without submitting
them, and logs `outcome="ok"` while doing so. A script driving a pane would read
success and move on. The working substitute is `herdr pane send-keys <pane>
enter` — which, unlike `agent.prompt`, is not recorded in the server log at all.
The input path that fails is audited; the one that succeeds is invisible.

`done` — the state meaning "the agent finished while you weren't looking" —
exists only while a client is attached, and is cleared by the act of detaching.
This is by design rather than a defect: `done` feeds `[ui.toast]`, a client-side
concept, so with nobody attached there is nobody to notify. It was built for
"attached but looking at another pane," not "away from the machine."

## Decision

**1. Herdr is adopted for session persistence on the Pi, and not as the standing
way long agent work is run.** It keeps a wipe-cycle session alive across the
wifi drops this box is prone to, which is a real gain over a bare SSH session.
It does not become the assumed substrate for item 4 until it can be driven
programmatically, because the moment a script depends on `agent prompt` it
depends on a call that lies about succeeding.

**2. Agent status is advisory, not authoritative.** Nothing in this lab may gate
a destructive action — a wipe, a power cycle, a config push — on herdr's
`agent_status`. Detection is regex matching against another program's cosmetics,
and its failure mode is not an error but a confident, wrong `idle`. Reading it
for convenience is fine; branching on it before something irreversible is not.

**3. Drift is monitored rather than prevented.**
`~/.local/bin/herdr-awareness-check` compares Claude Code's version against the
cached detection manifest and the fetch's own health, and reports divergence. It
runs from `~/.profile` at login and stays silent unless it has something to say.
On drift it deliberately does **not** update its baseline, so the warning
persists until the pairing has been verified by hand and explicitly acked.

**4. The detection manifest is deliberately left auto-updating, not pinned.**
Pinning was considered and rejected. It defends against a tampered manifest —
which can only cause a misreported state, since the rules are regexes that
execute nothing — while doing nothing about the real risk, staleness, and
actively causing it by cutting off the upstream fixes that track Claude Code's
UI. `[update] manifest_check` stays `true`. This is the one place in this lab's
toolchain where an unpinned network fetch is accepted on purpose, which is worth
stating plainly given that herdr's own binary was sha256-verified against the
published digest and its installer curl-pipe deliberately refused.

**5. Notification of "finished while away" is not herdr's job.** Herdr
structurally cannot do it — its notion of notifying requires you to be present.
If that signal is ever wanted, it comes from a Claude Code `Stop` hook, which
fires regardless of attachment and regardless of whether herdr is running at
all. Not built; not currently wanted.

## Consequences

**What this buys.** A wipe-and-provision session on the Pi that survives the
wifi link dropping, with scrollback intact — removing a failure mode that would
otherwise cost a restarted session on the box that hosts the whole provisioning
cycle. Plus a working/idle signal over a socket API that `tmux` cannot provide,
usable for observation.

**What this costs.** A second moving part on the provisioning host, whose agent
awareness is coupled to another program's UI chrome and which will break
silently rather than loudly when that chrome moves. Decision 3 converts that
from a silent failure into a login-time warning, but does not remove it: the
check compares *inputs* to detection and cannot prove detection is correct.

**What this forecloses.** Nothing permanently. If `agent prompt` is fixed
upstream, decision 1 can be revisited without unwinding anything — the
persistence use is a strict subset of the driving use.

## Deferred

- **A functional probe.** Driving a pane through a known working→idle cycle and
  asserting herdr observed both edges would be ground truth, and would catch
  everything the version comparison in decision 3 cannot. It depends on the
  `send-keys` wrapper below, so it waits on the same thing.
- **A wrapper for the submit bug** (`agent prompt` followed by `send-keys
  enter`). The mechanism is proven by hand but not scripted, because building it
  would create exactly the script-driving dependency decision 1 declines to take
  on while the underlying call misreports success.
- **Standing permission for herdr to drive agent sessions.** Claude Code's
  auto-mode classifier blocked `herdr agent prompt` during the trial, correctly.
  Granting it is a real decision, made worse by `pane.*` calls leaving no audit
  trail, and should be decided deliberately rather than as a side effect of
  unblocking one command.
- **FirstMate, Treehouse and No Mistakes** — the rest of the workflow that
  prompted this trial. Skipped before it began and still skipped. FirstMate
  tracks upstream `main` unpinned and loads executable TypeScript into the agent
  session; Treehouse largely duplicates `claude --worktree` plus the existing
  one-concern-one-branch discipline. Evaluate separately, if ever.

## Alternatives Considered

| Option | Reason Not Chosen |
|--------|-------------------|
| `tmux` for persistence, nothing more | Does the persistence job with one `apt install` and no network-fetched manifest deciding what the tool believes. Rejected only because herdr's detached working/idle signal is real and `tmux` has no equivalent — but this stays the fallback if decision 3 starts firing regularly |
| Adopt herdr as the standing agent workspace now | Would put item 4's harness on top of `agent prompt`, a call that delivers keystrokes without submitting them and reports success anyway. A harness that silently does nothing is worse than no harness |
| Pin the detection manifest locally | Defends against the low-severity risk (a tampered regex file that can only misreport state) at the cost of guaranteeing the high-severity one (staleness against a UI that moves). Available as one line — `[update] manifest_check = false` — if the trade is ever re-decided |
| Replace screen-scraping with an event-driven hook reporting real lifecycle state | Not possible. `pane.report_agent` was tested with the official source string and a fresh sequence and is ignored for Claude Code; the screen manifest is the sole authority |
| Treat `agent_status` as authoritative and gate wipe cycles on it | The failure mode is a confident wrong `idle`, not an error. Gating a NAND format on a regex match against a spinner character is the kind of dependency this lab exists to *find*, not to build |
| Run the trial on the Windows PC instead | Herdr ships stable builds for Linux and macOS only; Windows is preview-channel, with broken terminal attach and remote mode, and known Shift+Enter and cwd-tracking faults that hit Claude Code directly |
