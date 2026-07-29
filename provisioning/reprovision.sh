#!/usr/bin/env bash
#
# netops-lab — one wipe-to-provisioned cycle.
#
# Run on goguma. Start this, then power-cycle the router. That is the entire
# procedure: no button hold, no console, no serial adapter — provided the board
# is armed with boot-device=try-ethernet-once-then-nand, which the provisioning
# script sets and which survives a Netinstall.
#
# Why this exists: decisions/005 wants the whole cycle driven from one box,
# because a wipe that takes a remembered command line is a wipe that stops
# getting run. Item 4 needs repeat cycles to be boring.
#
# A FACTORY board is the exception. It ships with device-mode `routerboard: no`,
# which blocks arming entirely, and it is not armed anyway — so the first cycle
# on a new device needs the reset-button hold, plus a one-time:
#     /system device-mode update routerboard=yes     (then a power cycle)
# See docs/bring-up-notes.md.

set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/netops-lab}"
NETINSTALL_DIR="${NETINSTALL_DIR:-$HOME/netinstall}"
NPK="${NPK:-routeros-7.20.8-arm.npk}"
LAB_IFACE="${LAB_IFACE:-eth0}"

CONFIG_SCRIPT="$REPO_DIR/provisioning/default-config.rsc"
KNOWN_HOSTS_LAB="$HOME/.ssh/known_hosts.lab"

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

finish() {
    local rc=$?
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

# The link must be up before starting. nmcli will happily configure an address
# on an unplugged interface, so a correct-looking `ip addr` proves nothing —
# check the carrier.
ip -br link show "$LAB_IFACE" | grep -q 'UP' \
    || die "$LAB_IFACE is not UP — is the cable in the router's ether1?"

# The lab link must never hold the default route. If it does, the SSH session
# running this script is about to be cut by the wipe it started.
if ip route show default | grep -q "dev $LAB_IFACE"; then
    die "default route is via $LAB_IFACE — refusing to wipe the router you are reached through"
fi

# --- Host keys ---------------------------------------------------------------
# Netinstall regenerates the router's SSH host keys, so the stored entry is
# guaranteed stale after this runs. Deleting the whole file is safe *because*
# it is a lab-only known-hosts file — see the lab-router block in ~/.ssh/config.
# Never do this to the real ~/.ssh/known_hosts.

emit preflight_ok

rm -f "$KNOWN_HOSTS_LAB"

# --- Run ---------------------------------------------------------------------
# -i binds the BOOTP server to the lab link. This is a safety flag, not a
# tidiness one: the Pi is dual-homed onto the house network, and an unbound
# server would answer on wlan0 too.
#
# -r applies the default configuration; -s makes that default configuration
# ours. sudo because BOOTP and TFTP bind privileged ports.

echo "Starting Netinstall on $LAB_IFACE. Power-cycle the router now."
echo

cd "$NETINSTALL_DIR"

# `set -e` would abort before the end event could be written, and a run that
# vanishes on failure is exactly what this log exists to make impossible. So the
# exit status is captured deliberately rather than inherited.
NI_START=$SECONDS
emit netinstall_start
set +e
sudo qemu-i386-static ./netinstall-cli \
    -i "$LAB_IFACE" \
    -r \
    -s "$CONFIG_SCRIPT" \
    "$NPK"
NI_RC=$?
set -e

if [ "$NI_RC" -eq 0 ]; then
    emit netinstall_end "\"ok\":true,\"exit\":0,\"seconds\":$((SECONDS - NI_START))"
else
    emit netinstall_end "\"ok\":false,\"exit\":$NI_RC,\"seconds\":$((SECONDS - NI_START))"
    die "netinstall-cli exited $NI_RC"
fi

cat <<'EOF'

Done. Verify with:

    ssh lab-router "/system resource print"

That should print with no prompts of any kind. If it asks for a passphrase,
the agent is not loaded — ssh-add ~/.ssh/id_ed25519. The agent does not
survive a Pi reboot; that limitation is deliberate and recorded in
decisions/006.

Worth checking on the first run after any change to default-config.rsc:

    ssh lab-router "/ip firewall filter print"    # management accept ABOVE the !LAN drop
    ssh lab-router "/system routerboard settings print"   # still armed for next cycle

A successful ping proves nothing here — the config accepts ICMP with no
interface restriction, so it answers whether or not management works.
EOF

# Said last and said plainly: the log records that netinstall exited 0, which is
# not the same claim as "the router is provisioned and reachable." The two ssh
# checks above are still the only thing that establishes that, and they are still
# manual. A run marked ok in this file means the install ran, nothing more.
printf '\nRun logged to %s (install outcome only — verification above is still by hand).\n' "$RUN_LOG"
