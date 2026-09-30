#!/usr/bin/env bash
#
# netops-lab — check FRR on goguma: OSPF, eBGP, and the route guard.
#
# Run on the Pi, after provisioning/frr-install.sh and provisioning/frr-router.rsc:
#
#     sudo ./provisioning/frr-verify.sh
#
# It prints three vtysh outputs for a human to read:
#
#     show ip ospf neighbor
#     show bgp summary
#     show ip route
#
# Then it checks four things and exits non-zero when one fails:
#
#   1. An OSPF neighbor is Full.
#   2. The BGP session to the hEX is Established.
#   3. The hEX router ID (10.255.0.1/32) is in the kernel, via the lab link.
#      This proves that FIB-GUARD lets the lab routes through.
#   4. No default route is via the lab link. This is the self-lockout check,
#      the same one reprovision.sh makes before a wipe.
#
# Read-only. It changes nothing on the Pi and nothing on the router.
# The run sheet is docs/frr-bringup.md. The decision is decisions/010.

set -euo pipefail

LAB_IFACE="${LAB_IFACE:-eth0}"
ROUTER_LINK_ADDR="${ROUTER_LINK_ADDR:-192.168.99.1}"
ROUTER_ID="${ROUTER_ID:-10.255.0.1}"

die() { printf 'frr-verify: %s\n' "$1" >&2; exit 2; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"
command -v vtysh >/dev/null || die "vtysh not found; run provisioning/frr-install.sh first"
systemctl is-active --quiet frr || die "frr is not active; read: journalctl -u frr -n 50"

# A vtysh failure prints its own error and must not stop the report, so each
# call is captured with "|| true". The checks below then fail on the content.
vt() {
    vtysh -c "$1" 2>&1 || true
}

section() {
    printf '\n=== %s ===\n' "$1"
}

section "show ip ospf neighbor"
ospf_out="$(vt "show ip ospf neighbor")"
printf '%s\n' "$ospf_out"

section "show bgp summary"
vt "show bgp summary"

section "show ip route"
vt "show ip route"

# --- Checks ------------------------------------------------------------------
# Matched with case on captured text, not with grep -q in a pipe. Under
# pipefail, an early grep exit can make a match read as a failure.

FAILS=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }

section "checks"

# 1. OSPF. A point-to-point neighbor shows "Full/-". A broadcast one shows
#    "Full/DR" or "Full/Backup". All start with "Full/".
case "$ospf_out" in
    *"Full/"*) pass "OSPF neighbor is Full" ;;
    *) fail "no OSPF neighbor is Full (docs/frr-bringup.md, Troubleshooting)" ;;
esac

# 2. BGP. The neighbor detail states the FSM state in plain words, which is a
#    firmer match than a column in the summary table.
bgp_out="$(vt "show bgp neighbors $ROUTER_LINK_ADDR")"
case "$bgp_out" in
    *"BGP state = Established"*) pass "BGP session to $ROUTER_LINK_ADDR is Established" ;;
    *) fail "BGP session to $ROUTER_LINK_ADDR is not Established (docs/frr-bringup.md, Troubleshooting)" ;;
esac

# 3. The hEX router ID is in the kernel via the lab link.
rid_route="$(ip -4 route show "$ROUTER_ID" 2>/dev/null || true)"
case "$rid_route" in
    *"dev $LAB_IFACE"*) pass "$ROUTER_ID is in the kernel via $LAB_IFACE" ;;
    *) fail "$ROUTER_ID is not in the kernel via $LAB_IFACE (OSPF down, or FIB-GUARD blocks it)" ;;
esac

# 4. The self-lockout check. A routing table that cannot be read is a failure.
if ! default_routes="$(ip -4 route show default 2>/dev/null)"; then
    fail "cannot read the routing table"
else
    case "$default_routes" in
        *"dev $LAB_IFACE"*)
            fail "a default route is via $LAB_IFACE; roll back now (docs/frr-bringup.md, Rollback)"
            ;;
        *)
            pass "no default route is via $LAB_IFACE"
            ;;
    esac
fi

if [ "$FAILS" -gt 0 ]; then
    printf '\nfrr-verify: %d check(s) failed\n' "$FAILS" >&2
    exit 1
fi

printf '\nfrr-verify: all checks passed\n'
