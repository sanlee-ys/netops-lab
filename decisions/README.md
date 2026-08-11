# Architecture Decision Log

Decisions are recorded here as they are made. Each ADR captures the context,
the decision, and the consequences — including trade-offs accepted.

| # | Title | Status |
|---|-------|--------|
| [001](001-hardware-substrate-scope.md) | Hardware substrate, not a simulator — and what's explicitly out of scope | Accepted |
| [002](002-keep-the-hex-decline-rb5009.md) | Keep the hEX, decline the RB5009 upgrade | Accepted |
| [003](003-on-router-containers.md) | On-router containers — possible on this board, still not used | Accepted |
| [004](004-research-standing-of-the-agent-experiment.md) | Research standing of the agent experiment: what's claimable and what isn't | Accepted |
| [005](005-pi-as-ztp-host.md) | The Pi is the ZTP host — Netinstall-driven, armed for repeat cycles | Accepted |
| [006](006-management-surface-on-ether1.md) | The management surface the provisioning script opens on ether1 | Accepted |
| [007](007-herdr-as-agent-workspace.md) | Herdr is the agent workspace on the Pi — for persistence, not for driving | Accepted |
| [008](008-unattended-wipe-cycle.md) | The wipe cycle runs unattended — one command, no physical action | Accepted |
| [009](009-wireguard-endpoint-and-uplink.md) | WireGuard endpoint on the hEX, house uplink on ether5 | Accepted |

## Format

Each ADR follows this structure:

- **Context** — what problem or decision point prompted this
- **Decision** — what was chosen
- **Consequences** — what the decision enables, what it costs, what it forecloses
- **Alternatives Considered** — what was ruled out and why

Statuses: `Proposed` → `Accepted` → `Superseded` / `Deprecated`
