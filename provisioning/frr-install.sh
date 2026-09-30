#!/usr/bin/env bash
#
# netops-lab — install FRR on goguma and put the lab OSPF/eBGP config in place.
#
# Run on the Pi, from the repo, AFTER provisioning/frr-router.rsc is on the hEX:
#
#     sudo ./provisioning/frr-install.sh --dry-run   # read-only checks, print the plan
#     sudo ./provisioning/frr-install.sh             # do it
#
# A dry run works without root, but vtysh may then fail to read its own
# config and report that as a rejection. Use sudo for both.
#
# Then:
#
#     sudo ./provisioning/frr-verify.sh
#
# The run sheet is docs/frr-bringup.md. The decision is decisions/010.
#
# What it does, in order:
#   1. Preflight (read-only): the lab link is UP and holds its address, the
#      default route is NOT via the lab link, the repo files are present.
#   2. apt-get install frr, if it is not installed.
#   3. vtysh --dryrun on frr/frr.conf. A syntax error stops the script here,
#      before /etc/frr changes.
#   4. Copy frr/daemons and frr/frr.conf to /etc/frr when they differ. The
#      package copies are kept once as *.netops-lab.orig.
#   5. systemctl enable frr, and restart it only when a file changed.
#   6. Route guard: for GUARD_SECONDS, check that the default route and the
#      route to the default gateway did not move. If one moved, stop FRR,
#      flush the OSPF and BGP kernel routes, and exit non-zero.
#
# Idempotent. A second run with no change in frr/ restarts nothing.
#
# SELF-LOCKOUT. Step 5 is the step that can cut you off. If the Pi installs a
# default route, or a route to the house LAN, via eth0, the Pi's traffic
# leaves through the hEX, and the hEX drops new connections from ether1 (the
# forward drop in default-config.rsc). The first guard is FIB-GUARD in
# frr/frr.conf, which never lets such a route into the kernel. Step 6 is the
# second guard, for the case where the first one is wrong. Do not remove either.
#
# This script does not touch eth0's address, its NetworkManager connection, or
# wlan0. It does not enable IP forwarding: the Pi is a host, not a router
# between the house LAN and the lab.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(dirname "$SCRIPT_DIR")}"
FRR_SRC="$REPO_DIR/frr"
FRR_DST="${FRR_DST:-/etc/frr}"
LAB_IFACE="${LAB_IFACE:-eth0}"
LAB_ADDR="${LAB_ADDR:-192.168.99.2/30}"
GUARD_SECONDS="${GUARD_SECONDS:-90}"

DRY_RUN=0

say() { printf 'frr-install: %s\n' "$1"; }
die() { printf 'frr-install: %s\n' "$1" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: frr-install.sh [--dry-run]

  --dry-run   Run the read-only checks and print each change. Change nothing.
              Use sudo anyway, so the vtysh check can read its config.

Environment overrides: REPO_DIR, FRR_DST, LAB_IFACE, LAB_ADDR, GUARD_SECONDS.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done

# Every change goes through run(). In a dry run it prints the command and
# returns 0, so the plan shows the full sequence.
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

# The "dev" field of the first line of an "ip route" output.
first_dev() {
    awk 'NR==1 { for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

# The "via" field of the first line of an "ip route" output.
first_via() {
    awk 'NR==1 { for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }'
}

# Captured to a variable and matched with case, not piped into grep -q. Under
# pipefail, a grep -q that stops early can SIGPIPE the writer and make a match
# read as a failure (the same reason as in reprovision.sh). A routing table
# that cannot be read is a failure, not "no default route".
read_default_routes() {
    ip -4 route show default 2>/dev/null
}

route_dev_for() {
    local out
    out="$(ip -4 route get "$1" 2>/dev/null)" || return 1
    printf '%s\n' "$out" | first_dev
}

# --- 1. Preflight (read-only) ------------------------------------------------

if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    die "run as root: sudo $0 (or use --dry-run)"
fi

[ -r "$FRR_SRC/daemons" ] || die "missing $FRR_SRC/daemons (is the repo pulled?)"
[ -r "$FRR_SRC/frr.conf" ] || die "missing $FRR_SRC/frr.conf (is the repo pulled?)"

command -v apt-get >/dev/null \
    || die "apt-get not found; this script is for Debian or Raspberry Pi OS"
command -v ip >/dev/null || die "ip not found; apt install iproute2"

# Read the state column, not the whole line. The flags column of an unplugged
# but admin-up interface contains ",UP>" (see reprovision.sh).
link_state="$(ip -br link show "$LAB_IFACE" 2>/dev/null | awk 'NR==1 { print $2 }' || true)"
[ "$link_state" = "UP" ] \
    || die "$LAB_IFACE is not UP (state: ${link_state:-unknown}); is the cable in the hEX ether1?"

lab_addrs="$(ip -br -4 addr show dev "$LAB_IFACE" 2>/dev/null || true)"
case "$lab_addrs" in
    *"$LAB_ADDR"*) ;;
    *) die "$LAB_IFACE does not hold $LAB_ADDR; bring up the NetworkManager connection \"lab\" first" ;;
esac

if ! default_routes="$(read_default_routes)"; then
    die "cannot read the routing table; refusing to continue without the default route"
fi
case "$default_routes" in
    *"dev $LAB_IFACE"*)
        die "the default route is already via $LAB_IFACE; fix that before FRR runs (docs/frr-bringup.md)"
        ;;
esac

BEFORE_DEFAULT_DEV="$(printf '%s\n' "$default_routes" | first_dev)"
DEFAULT_GW="$(printf '%s\n' "$default_routes" | first_via)"
BEFORE_GW_DEV=""
if [ -n "$DEFAULT_GW" ]; then
    BEFORE_GW_DEV="$(route_dev_for "$DEFAULT_GW" || true)"
fi
say "default route dev: ${BEFORE_DEFAULT_DEV:-none}; gateway ${DEFAULT_GW:-none} via ${BEFORE_GW_DEV:-none}"

ip_forward="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo unknown)"
if [ "$ip_forward" = "1" ]; then
    say "WARNING: net.ipv4.ip_forward=1. The Pi then routes between wlan0 and eth0."
    say "         decisions/010 keeps the Pi a host. This script does not change it."
fi

# --- 2. Package --------------------------------------------------------------

# shellcheck disable=SC2016
# ${Status} is a dpkg-query format field, not a shell variable. The single
# quotes are correct.
frr_status="$(dpkg-query -W -f='${Status}' frr 2>/dev/null || true)"
case "$frr_status" in
    "install ok installed")
        say "frr is installed"
        ;;
    *)
        say "frr is not installed; installing"
        run apt-get update
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y frr
        ;;
esac

# --- 3. Check the config before it goes into /etc/frr ------------------------

if command -v vtysh >/dev/null; then
    if ! vtysh --dryrun -f "$FRR_SRC/frr.conf" >/dev/null; then
        die "vtysh --dryrun rejected $FRR_SRC/frr.conf; /etc/frr is unchanged (not root? use sudo)"
    fi
    say "vtysh --dryrun accepted frr/frr.conf"
else
    say "skip: vtysh is not installed yet, so the config check runs on the real install"
fi

# --- 4. Place the files ------------------------------------------------------

CHANGED=0

place() {
    local name="$1"
    local src="$FRR_SRC/$name"
    local dst="$FRR_DST/$name"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        say "$dst is current"
        return 0
    fi
    if [ -f "$dst" ] && [ ! -f "$dst.netops-lab.orig" ]; then
        run cp -p "$dst" "$dst.netops-lab.orig"
    fi
    run install -o frr -g frr -m 0640 "$src" "$dst"
    CHANGED=1
}

place daemons
place frr.conf

# --- 5. Enable and restart ---------------------------------------------------

if ! systemctl is-enabled --quiet frr 2>/dev/null; then
    run systemctl enable frr
fi

RESTARTED=0
if [ "$CHANGED" -eq 1 ] || ! systemctl is-active --quiet frr 2>/dev/null; then
    run systemctl restart frr
    RESTARTED=1
else
    say "no file changed and frr is active; no restart"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    say "dry run complete; nothing changed"
    exit 0
fi

systemctl is-active --quiet frr \
    || die "frr is not active after restart; read: journalctl -u frr -n 50"

# --- 6. Route guard ----------------------------------------------------------

stop_and_flush() {
    systemctl stop frr || true
    ip -4 route flush proto ospf 2>/dev/null || true
    ip -4 route flush proto bgp 2>/dev/null || true
}

guard_once() {
    local routes gw_dev
    if ! routes="$(read_default_routes)"; then
        printf 'cannot read the routing table'
        return 1
    fi
    case "$routes" in
        *"dev $LAB_IFACE"*)
            printf 'a default route is now via %s' "$LAB_IFACE"
            return 1
            ;;
    esac
    if [ -n "$DEFAULT_GW" ] && [ -n "$BEFORE_GW_DEV" ]; then
        gw_dev="$(route_dev_for "$DEFAULT_GW" || true)"
        if [ "$gw_dev" != "$BEFORE_GW_DEV" ]; then
            printf 'the route to %s moved from %s to %s' "$DEFAULT_GW" "$BEFORE_GW_DEV" "${gw_dev:-none}"
            return 1
        fi
    fi
    return 0
}

if [ "$RESTARTED" -eq 1 ]; then
    say "watching the default route for ${GUARD_SECONDS}s (OSPF and BGP come up in this window)"
    deadline=$((SECONDS + GUARD_SECONDS))
else
    deadline=$SECONDS
fi

while :; do
    if ! reason="$(guard_once)"; then
        stop_and_flush
        die "ROUTE GUARD: $reason. FRR is stopped and its kernel routes are flushed. Read docs/frr-bringup.md, section Rollback."
    fi
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 5
done

say "route guard passed; the default route is still via ${BEFORE_DEFAULT_DEV:-none}"
cat <<'EOF'

Next:

    sudo ./provisioning/frr-verify.sh

EOF
