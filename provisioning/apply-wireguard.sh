#!/usr/bin/env bash
#
# netops-lab — apply (or refresh) the WireGuard endpoint on the hEX.
#
# Run on goguma, after the router is provisioned and reachable:
#
#     ./provisioning/apply-wireguard.sh
#
# Keys live on the Pi, not in git (decisions/009):
#
#     ~/.config/netops-lab/wg-lab.private     # server private key (create once)
#     ~/.config/netops-lab/wg-client-san.public  # San's client public key
#
# First-time key material (on the Pi):
#
#     mkdir -p ~/.config/netops-lab && chmod 700 ~/.config/netops-lab
#     # Server key: let RouterOS generate once, then export and store:
#     #   ssh lab-router "/interface wireguard add name=wg-lab listen-port=51820"
#     #   ssh lab-router "/interface wireguard print detail"
#     #   paste private-key into wg-lab.private (single line), then remove the
#     #   interface and re-run this script — or use any wg-compatible keygen
#     #   that emits a RouterOS-format private key.
#     #
#     # Client: on the laptop,
#     #   wg genkey | tee client.private | wg pubkey > client.public
#     #   scp client.public goguma:~/.config/netops-lab/wg-client-san.public
#
# Idempotent: safe to re-run after every wipe. reprovision.sh calls this when
# wg-lab.private exists.

set -euo pipefail

ROUTER_SSH="${ROUTER_SSH:-lab-router}"
WG_PORT="${WG_PORT:-51820}"
WG_IF="${WG_IF:-wg-lab}"
WG_ADDR="${WG_ADDR:-10.99.0.1/24}"
PEER_ADDR="${PEER_ADDR:-10.99.0.2/32}"
KEY_DIR="${KEY_DIR:-$HOME/.config/netops-lab}"
SERVER_PRIVATE_FILE="${SERVER_PRIVATE_FILE:-$KEY_DIR/wg-lab.private}"
CLIENT_PUBLIC_FILE="${CLIENT_PUBLIC_FILE:-$KEY_DIR/wg-client-san.public}"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5)

die() { printf 'apply-wireguard: %s\n' "$1" >&2; exit 1; }

[ -f "$SERVER_PRIVATE_FILE" ] || die "missing $SERVER_PRIVATE_FILE — see header"
[ -f "$CLIENT_PUBLIC_FILE" ] || die "missing $CLIENT_PUBLIC_FILE — see header"

# Single-line keys, no comments. RouterOS is picky about whitespace.
SERVER_PRIVATE="$(tr -d '[:space:]' <"$SERVER_PRIVATE_FILE")"
CLIENT_PUBLIC="$(tr -d '[:space:]' <"$CLIENT_PUBLIC_FILE")"
[ -n "$SERVER_PRIVATE" ] || die "empty server private key"
[ -n "$CLIENT_PUBLIC" ] || die "empty client public key"

ssh_r() {
    ssh "${SSH_OPTS[@]}" "$ROUTER_SSH" "$@"
}

ssh_r "/system resource print" >/dev/null 2>&1 \
    || die "router not reachable as $ROUTER_SSH"

# Remove a prior interface so private-key and listen-port converge to the files
# on disk. Peers go with the interface.
if ssh_r "/interface wireguard print where name=\"$WG_IF\"" 2>/dev/null | grep -q "$WG_IF"; then
    ssh_r "/interface wireguard remove [find name=\"$WG_IF\"]"
fi

# RouterOS accepts the private key as a property on add.
ssh_r "/interface wireguard add name=\"$WG_IF\" listen-port=$WG_PORT private-key=\"$SERVER_PRIVATE\" comment=\"lab: decisions/009\""

# Address: replace if present.
ssh_r "/ip address remove [find interface=\"$WG_IF\"]" 2>/dev/null || true
ssh_r "/ip address add address=$WG_ADDR interface=\"$WG_IF\" comment=\"lab: WireGuard tunnel\""

# LAN-list membership so the !LAN input drop does not eat tunnel traffic.
if ! ssh_r "/interface list member print where interface=\"$WG_IF\" and list=LAN" 2>/dev/null | grep -q "$WG_IF"; then
    ssh_r "/interface list member add interface=\"$WG_IF\" list=LAN comment=\"lab: wg trusted tunnel\""
fi

# Single San peer. Remove peers on this interface first (interface recreate
# already did, but keep the script correct if add path changes).
ssh_r "/interface wireguard peers remove [find interface=\"$WG_IF\"]" 2>/dev/null || true
ssh_r "/interface wireguard peers add interface=\"$WG_IF\" public-key=\"$CLIENT_PUBLIC\" allowed-address=$PEER_ADDR comment=\"lab: San client\""

PUB="$(ssh_r "/interface wireguard get [find name=\"$WG_IF\"] public-key")"
WAN_IP="$(ssh_r "/ip dhcp-client get [find interface=ether5] address" 2>/dev/null || true)"

cat <<EOF

apply-wireguard: ok

  interface     $WG_IF
  listen        $WG_PORT/udp
  tunnel        $WG_ADDR
  peer (San)    $PEER_ADDR
  server pubkey $PUB
  ether5 lease  ${WAN_IP:-unknown — is ether5 cabled to the house LAN?}

House router still needs UDP $WG_PORT forwarded to ether5's address (use a
DHCP reservation). Client allowed-ips typically:

  10.99.0.0/24, 192.168.88.0/24, 192.168.99.0/30

EOF
