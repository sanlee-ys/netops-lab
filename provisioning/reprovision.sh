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

die() { printf 'reprovision: %s\n' "$1" >&2; exit 1; }

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
sudo qemu-i386-static ./netinstall-cli \
    -i "$LAB_IFACE" \
    -r \
    -s "$CONFIG_SCRIPT" \
    "$NPK"

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
