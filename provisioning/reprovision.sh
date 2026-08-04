#!/usr/bin/env bash
#
# netops-lab — one wipe-to-provisioned cycle, unattended.
#
# Run on goguma. One command, no physical action:
#
#     ./reprovision.sh
#
# It arms the board, starts the Netinstall server, waits until that server is
# genuinely listening, reboots the router into it over SSH, and then verifies
# the result. No button hold, no console, no serial adapter, and no power cycle.
#
# Why the power cycle is gone (verified 2026-08-03): RouterBOOT runs its
# boot-device logic on EVERY boot, so `/system reboot` reaches Etherboot exactly
# as pulling the plug does. The plug was never the trigger; any boot is. It also
# returns cleanly over a non-interactive SSH with no confirmation prompt.
#
# THE ARM IS A ONE-SHOT. `try-ethernet-once-then-nand` is consumed by the next
# boot — server listening or not — and RouterBOOT then reverts the stored value
# to its default. So a board that has restarted since it was provisioned is NOT
# armed, which is why this script arms immediately before rebooting rather than
# trusting the arm that decisions/005 sets at provision time. Both arming points
# are wanted; they cover different failures. See docs/bring-up-notes.md.
#
# Why this exists: decisions/005 wants the whole cycle driven from one box,
# because a wipe that takes a remembered command line is a wipe that stops
# getting run. Item 4 needs repeat cycles to be boring.
#
# THIS SCRIPT WIPES A ROUTER WITH NO SECOND HUMAN ACTION. That is deliberate
# (decided 2026-08-03) and it is worth stating plainly, because the power cycle
# it replaces was functioning as an accidental confirmation step. What actually
# protects you is the default-route preflight below, which refuses to wipe the
# router you are reached through. That check is load-bearing now in a way it
# was not before. Do not weaken it.
#
# UNREACHABLE BOARD: if SSH to the router fails, the script does NOT abort. It
# starts the server and asks for a power cycle instead. That is the lockout
# recovery case — the board cannot be armed or rebooted over a management path
# that is already broken, and a human is present by definition. Refusing to run
# there would block the one case Netinstall exists for.
#
# A FACTORY board is the other exception. It ships with device-mode
# `routerboard: no`, which blocks arming entirely, and it is not armed anyway —
# so the first cycle on a new device needs the reset-button hold, plus a
# one-time:
#     /system device-mode update routerboard=yes     (then a power cycle)
# See docs/bring-up-notes.md.

set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/netops-lab}"
NETINSTALL_DIR="${NETINSTALL_DIR:-$HOME/netinstall}"
NPK="${NPK:-routeros-7.20.8-arm.npk}"
LAB_IFACE="${LAB_IFACE:-eth0}"
ROUTER_SSH="${ROUTER_SSH:-lab-router}"

CONFIG_SCRIPT="$REPO_DIR/provisioning/default-config.rsc"
KNOWN_HOSTS_LAB="$HOME/.ssh/known_hosts.lab"

# BOOTP's server port. This is the readiness gate: the server is ready when it
# holds this socket, which is a direct test of the thing that matters rather
# than an inference from log text. See wait_for_bootp().
BOOTP_PORT=67

# Timeouts, all overridable. Each one exists because the unattended path can
# hang where the attended path merely looked slow and a human gave up on it.
SERVER_READY_TIMEOUT="${SERVER_READY_TIMEOUT:-60}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-600}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-240}"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5)

NI_PID=""
NI_LOG=""

# --- Run log -----------------------------------------------------------------
# One JSON object per line, appended. The point is to be able to answer "is this
# actually repeatable" with a number instead of a memory: how many cycles, how
# many clean, how long, and which preflight check failed when one did.
#
# It defaults OUTSIDE the repo. Run data is machine state, not source, and a log
# that dirties the working tree on every cycle is a log that gets deleted.
#
# The design constraint that shaped everything below: a run that dies must leave
# a terminal event. A log where "failed" and "never finished" look identical is
# the failure this instrumentation exists to prevent, so the EXIT trap is not a
# nicety -- it is the whole reason to trust a count taken from this file.

RUN_LOG="${RUN_LOG:-$HOME/netops-lab-runs.ndjson}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_ENDED=0

# Values here are paths and shell messages, so escape the two characters that
# would otherwise produce invalid JSON. Nothing interpolated is user input, but a
# path with a quote in it should corrupt one field rather than the whole file.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

emit() {
    local event="$1"; shift
    local extra="${1:-}"
    mkdir -p "$(dirname "$RUN_LOG")" 2>/dev/null || true
    printf '{"ts":"%s","run":"%s","event":"%s","elapsed":%d%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUN_ID" "$event" "$SECONDS" \
        "${extra:+,$extra}" >> "$RUN_LOG"
}

# The server now outlives individual steps, so an abort between starting it and
# reaping it would leave a root-owned BOOTP/TFTP server bound to the lab link.
# On a dual-homed box that is exactly the rogue service the -i flag exists to
# prevent, so cleanup is not tidiness -- it is the same safety property.
stop_server() {
    [ -n "$NI_PID" ] || return 0
    kill -0 "$NI_PID" 2>/dev/null || return 0
    # NI_PID is the sudo wrapper, which runs as root: an unprivileged signal
    # will not reach it, so this needs sudo as well. The pkill afterwards is a
    # backstop for the qemu child outliving its parent, and it is scoped to the
    # one binary this lab ever runs under that name.
    sudo kill "$NI_PID" 2>/dev/null || true
    sleep 2
    sudo pkill -f netinstall-cli 2>/dev/null || true
}

finish() {
    local rc=$?
    stop_server
    [ "$RUN_ENDED" -eq 1 ] && return
    RUN_ENDED=1
    # An unhandled failure reaches here without a reason, which is worth saying
    # plainly rather than recording as a bare non-zero exit.
    if [ "$rc" -eq 0 ]; then
        emit run_end '"ok":true'
    else
        emit run_end "\"ok\":false,\"exit\":$rc,\"reason\":\"unhandled\""
    fi
}
trap finish EXIT

die() {
    RUN_ENDED=1
    emit run_end "\"ok\":false,\"exit\":1,\"reason\":\"$(json_escape "$1")\""
    printf 'reprovision: %s\n' "$1" >&2
    exit 1
}

emit run_start "\"iface\":\"$(json_escape "$LAB_IFACE")\",\"npk\":\"$(json_escape "$NPK")\""

# --- Preflight ---------------------------------------------------------------
# Every check below is here because it actually went wrong once. netinstall-cli
# validates its own script path before touching the router, which is the good
# failure mode, but the rest of these fail later and more expensively.

[[ -r "$CONFIG_SCRIPT" ]] \
    || die "config script not readable: $CONFIG_SCRIPT (is the repo cloned?)"

[[ -r "$NETINSTALL_DIR/$NPK" ]] \
    || die "package not found: $NETINSTALL_DIR/$NPK"

[[ -x "$NETINSTALL_DIR/netinstall-cli" ]] \
    || die "netinstall-cli not found in $NETINSTALL_DIR"

command -v qemu-i386-static >/dev/null \
    || die "qemu-i386-static missing — apt install qemu-user-static"

# netinstall-cli is an i386 binary and needs the i386 emulator specifically.
# Reaching for qemu-x86_64-static fails in a way that reads like a broken
# download rather than a wrong emulator.

command -v ss >/dev/null \
    || die "ss missing — apt install iproute2 (needed to detect server readiness)"

# sudo must be non-interactive. Attended, a password prompt was a pause; here it
# is a silent hang with a backgrounded root process on the far side of it.
sudo -n true 2>/dev/null \
    || die "sudo needs a password here — this script cannot run unattended until that is fixed"

# The link must be up before starting. nmcli will happily configure an address
# on an unplugged interface, so a correct-looking `ip addr` proves nothing —
# check the carrier.
ip -br link show "$LAB_IFACE" | grep -q 'UP' \
    || die "$LAB_IFACE is not UP — is the cable in the router's ether1?"

# The lab link must never hold the default route. If it does, the SSH session
# running this script is about to be cut by the wipe it started.
#
# This is now the ONLY thing standing between one command and wiped hardware,
# since the power cycle that used to require a human is gone. Treat it as such.
if ip route show default | grep -q "dev $LAB_IFACE"; then
    die "default route is via $LAB_IFACE — refusing to wipe the router you are reached through"
fi

# Not fatal: the agent is what makes the SSH steps below non-interactive, but a
# missing agent must not block the unreachable-board path, which needs no SSH at
# all. Warn, and let the reachability probe decide. decisions/006 records why
# the agent needs a human after a Pi reboot in the first place.
if ! ssh-add -l >/dev/null 2>&1; then
    printf 'reprovision: WARNING — no keys in ssh-agent (ssh-add ~/.ssh/id_ed25519).\n' >&2
    printf '             Arming and rebooting will fall back to a manual power cycle.\n' >&2
fi

emit preflight_ok

# --- Host keys ---------------------------------------------------------------
# Netinstall regenerates the router's SSH host keys, so the stored entry is
# guaranteed stale after this runs. Deleting the whole file is safe *because*
# it is a lab-only known-hosts file — see the lab-router block in ~/.ssh/config.
# Never do this to the real ~/.ssh/known_hosts.
#
# Cleared TWICE, and the ordering is load-bearing. Once here, so the pre-wipe
# arm and reboot can connect whatever stale key a previous cycle left behind
# (accept-new refuses a CHANGED key, which is precisely what a stale entry
# looks like). Once again after the reboot, because everything stored in the
# meantime describes a board that is about to stop existing.

rm -f "$KNOWN_HOSTS_LAB"

# --- Reachability ------------------------------------------------------------
# Decides between the unattended path and the recovery path. Deliberately a
# branch and not a gate: an unreachable router is the case Netinstall exists
# for, so failing here would refuse to run exactly when it is needed most.

ROUTER_REACHABLE=0
probe_err=""
if probe_err="$(ssh "${SSH_OPTS[@]}" "$ROUTER_SSH" "/system identity print" 2>&1)"; then
    ROUTER_REACHABLE=1
    emit router_probe '"reachable":true'
else
    emit router_probe "\"reachable\":false,\"detail\":\"$(json_escape "$(printf '%s' "$probe_err" | tr '\n' ' ')")\""
fi

# --- Arm ---------------------------------------------------------------------
# Before the server starts, so a board that cannot be armed fails fast instead
# of after a wipe window is already open.
#
# Arming is not idempotent in the way it looks: it sets a one-shot. If this
# succeeds and a later step dies, the arm survives until the next boot spends
# it harmlessly against a server that is not there. That is wasteful, not
# dangerous, and it is the reason arming is safe to do this early.

if [ "$ROUTER_REACHABLE" -eq 1 ]; then
    if ! ssh "${SSH_OPTS[@]}" "$ROUTER_SSH" \
        "/system routerboard settings set boot-device=try-ethernet-once-then-nand" >/dev/null 2>&1; then
        die "could not arm the board — check device-mode routerboard=yes (see docs/bring-up-notes.md)"
    fi

    # Read it back rather than trusting the exit status. RouterOS accepts the
    # command and reports failure in ways that are easy to miss non-interactively,
    # and an unarmed board here means the reboot below is a no-op that ends in a
    # server waiting until INSTALL_TIMEOUT for a device that never offers itself.
    armed="$(ssh "${SSH_OPTS[@]}" "$ROUTER_SSH" "/system routerboard settings print" 2>/dev/null || true)"
    case "$armed" in
        *try-ethernet-once-then-nand*) emit arm_ok ;;
        *)
            emit arm_failed
            die "board did not take the arm (boot-device is not try-ethernet-once-then-nand)"
            ;;
    esac
fi

# --- Start the server --------------------------------------------------------
# -i binds the BOOTP server to the lab link. This is a safety flag, not a
# tidiness one: the Pi is dual-homed onto the house network, and an unbound
# server would answer on wlan0 too.
#
# -r applies the default configuration; -s makes that default configuration
# ours. sudo because BOOTP and TFTP bind privileged ports.
#
# Backgrounded, because the reboot has to be issued while this is listening.
# Output goes to a file so a failure can be shown rather than described.

NI_LOG="$(mktemp -t netops-netinstall.XXXXXX)"

echo "Starting Netinstall on $LAB_IFACE (log: $NI_LOG)"

cd "$NETINSTALL_DIR"

NI_START=$SECONDS
emit netinstall_start
# shellcheck disable=SC2024
# SC2024 warns that sudo does not apply to the redirect. That is true and it is
# the intent: NI_LOG comes from mktemp and is owned by the invoking user, so the
# unprivileged shell can write it, and the failure paths below can `cat` and
# `rm` it without sudo. A root-owned log would need sudo to read the one thing
# you want to read when a run goes wrong.
sudo qemu-i386-static ./netinstall-cli \
    -i "$LAB_IFACE" \
    -r \
    -s "$CONFIG_SCRIPT" \
    "$NPK" >"$NI_LOG" 2>&1 &
NI_PID=$!

# Readiness is measured by the socket, not by the log.
#
# Two reasons, and the second is why this is not merely a preference. Matching
# vendor log text ties the cycle to one build's wording. And netinstall-cli is a
# STATICALLY linked binary under user-mode QEMU, so its stdout is block-buffered
# into a file and `stdbuf` cannot fix that — stdbuf works by LD_PRELOAD, which
# does nothing to a static binary. The obvious fix is unavailable; the socket is
# a better question to ask anyway.
wait_for_bootp() {
    local deadline=$((SECONDS + SERVER_READY_TIMEOUT))
    local listeners
    while [ "$SECONDS" -lt "$deadline" ]; do
        if ! kill -0 "$NI_PID" 2>/dev/null; then
            return 2
        fi
        # Captured to a variable rather than piped into grep -q: under pipefail
        # a short-circuiting grep can SIGPIPE the writer and turn a successful
        # match into a failed pipeline.
        listeners="$(ss -lun 2>/dev/null || true)"
        case "$listeners" in
            *":${BOOTP_PORT} "*) return 0 ;;
        esac
        sleep 1
    done
    return 1
}

set +e
wait_for_bootp
READY_RC=$?
set -e

case "$READY_RC" in
    0) emit server_ready "\"seconds\":$((SECONDS - NI_START))" ;;
    2)
        emit server_failed '"reason":"exited_before_listening"'
        printf 'reprovision: netinstall-cli exited before it started listening. Output:\n' >&2
        cat "$NI_LOG" >&2
        die "netinstall-cli died during startup"
        ;;
    *)
        emit server_failed '"reason":"timeout"'
        printf 'reprovision: no BOOTP listener after %ss. Output so far:\n' "$SERVER_READY_TIMEOUT" >&2
        cat "$NI_LOG" >&2
        die "netinstall-cli never bound udp/$BOOTP_PORT"
        ;;
esac

# --- Reboot into it ----------------------------------------------------------
# Strictly after the server is listening. Reversing these spends the arm: the
# board would Etherboot, find nothing, fall through to NAND, and revert
# boot-device — leaving the cycle worse off than when it started, and needing a
# re-arm before it could be retried.

if [ "$ROUTER_REACHABLE" -eq 1 ]; then
    echo "Server is listening. Rebooting the router."
    # `|| true` because the box may drop the connection as it goes down, which
    # is a non-zero status for something that worked. The cost of swallowing a
    # genuine failure here is bounded: it surfaces as the install timeout, whose
    # message names an unarmed-or-unrebooted board as the likely cause.
    ssh "${SSH_OPTS[@]}" "$ROUTER_SSH" "/system reboot" >/dev/null 2>&1 || true
    emit reboot_sent
else
    emit awaiting_manual_power_cycle
    cat <<EOF

The router is NOT reachable over SSH, so it could not be armed or rebooted.
That is expected if you are recovering a locked-out or factory board.

    POWER-CYCLE THE ROUTER NOW.

A factory board, or one that is not armed, needs the reset-button hold instead:
power off, hold reset, power on, keep holding until it appears below.

Waiting up to ${INSTALL_TIMEOUT}s.

EOF
fi

# The board's identity changes with the wipe, so anything learned above is stale
# from here on. Cleared again so the verification step sees a first-seen key
# rather than a changed one.
rm -f "$KNOWN_HOSTS_LAB"

# --- Wait for the install ----------------------------------------------------
# A timeout, because unattended means nobody is watching to notice that nothing
# is happening. The commonest cause of reaching it is a board that was not armed
# at the moment it rebooted.

wait_for_install() {
    local deadline=$((SECONDS + INSTALL_TIMEOUT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        kill -0 "$NI_PID" 2>/dev/null || return 0
        sleep 2
    done
    return 1
}

set +e
wait_for_install
INSTALL_WAITED=$?
set -e

if [ "$INSTALL_WAITED" -ne 0 ]; then
    emit netinstall_end "\"ok\":false,\"reason\":\"timeout\",\"seconds\":$((SECONDS - NI_START))"
    printf 'reprovision: netinstall did not finish within %ss. Output:\n' "$INSTALL_TIMEOUT" >&2
    cat "$NI_LOG" >&2
    die "netinstall timed out — was the board actually armed when it rebooted?"
fi

NI_RC=0
wait "$NI_PID" || NI_RC=$?
NI_PID=""

if [ "$NI_RC" -eq 0 ]; then
    emit netinstall_end "\"ok\":true,\"exit\":0,\"seconds\":$((SECONDS - NI_START))"
else
    emit netinstall_end "\"ok\":false,\"exit\":$NI_RC,\"seconds\":$((SECONDS - NI_START))"
    cat "$NI_LOG" >&2
    die "netinstall-cli exited $NI_RC"
fi

# --- Verify ------------------------------------------------------------------
# netinstall exiting 0 means the install ran. It is NOT the same claim as "the
# router is provisioned and reachable", and this script used to stop short of
# that distinction and say so. It no longer has to: one non-interactive SSH
# exercises the whole chain at once — addressing, the management accept landing
# above the !LAN drop, the key import having run inside a first-boot script, and
# password login being off.
#
# A ping would prove none of it. The provisioned config accepts ICMP with no
# interface restriction, so it answers whether or not management works.

echo "Install finished. Waiting for the router to come back."

verify_router() {
    local deadline=$((SECONDS + VERIFY_TIMEOUT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if ssh "${SSH_OPTS[@]}" "$ROUTER_SSH" "/system resource print" >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    return 1
}

set +e
verify_router
VERIFY_RC=$?
set -e

if [ "$VERIFY_RC" -ne 0 ]; then
    emit verify_end '"ok":false,"reason":"unreachable"'
    die "install succeeded but the router never answered SSH — check the ssh-agent has the key loaded, then the firewall rule order and the key import"
fi

# Also confirm the provisioning script re-armed the board. That line is verified
# to run (2026-08-03), so a failure here is a real regression rather than an
# open question — and an unarmed board means the NEXT cycle would need this
# script's arm step, which needs the router reachable. Worth knowing now.
rearmed="$(ssh "${SSH_OPTS[@]}" "$ROUTER_SSH" "/system routerboard settings print" 2>/dev/null || true)"
case "$rearmed" in
    *try-ethernet-once-then-nand*) emit verify_end '"ok":true,"rearmed":true' ;;
    *)
        emit verify_end '"ok":false,"rearmed":false'
        die "router is up, but default-config.rsc did not re-arm it — the next cycle has no fallback"
        ;;
esac

rm -f "$NI_LOG"

cat <<'EOF'

Done, and verified. The router is provisioned, reachable by key, and re-armed.

Checks worth running by hand after any change to default-config.rsc:

    ssh lab-router "/ip firewall filter print"    # management accept ABOVE the !LAN drop
    ssh lab-router "/ipv6 firewall filter print"  # four input rules ending in the !LAN drop
    ssh lab-router "/ip firewall nat print"       # empty

EOF

# Said last and said plainly, because the log's credibility depends on it: a run
# marked ok in this file now means the install ran AND the router answered a
# non-interactive SSH AND it came back armed. It does not mean the firewall
# rules are in the intended order — that is what the commands above are for, and
# they are still by hand.
printf 'Run logged to %s (install + reachability + re-arm; rule ORDER is still checked by hand).\n' "$RUN_LOG"
