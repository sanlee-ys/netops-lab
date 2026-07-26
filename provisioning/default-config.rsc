# netops-lab — custom default-configuration script for the hEX refresh (E50UG)
#
# DRAFT. Not yet run. See "Unverified" below before trusting any of it.
#
# Installed with:
#   netinstall-cli -r -s default-config.rsc -i <iface> --mac <router-mac> routeros-*.npk
#
# `-s` replaces MikroTik's default configuration script. It has no minimum
# RouterOS version and survives both RouterOS updates and configuration
# resets, so this file defines the baseline the lab always returns to.
# `-sm` (one-time first-boot script) is deliberately not used: it requires
# RouterOS and Netinstall 7.22+, this board runs 7.20.8, and nothing here
# needs it. See decisions/006.
#
# Design rationale for every choice below lives in:
#   decisions/005-pi-as-ztp-host.md          — why the Pi, why ether1, why armed
#   decisions/006-management-surface-on-ether1.md — how wide, how authenticated
#
# Topology this assumes:
#   ether1        192.168.99.1/30   point-to-point management link to the Pi (.2)
#   ether2-5      bridge, 192.168.88.1/24, DHCP server — lab-facing LAN, San's PC
#
# ---------------------------------------------------------------------------
# UNVERIFIED — must be tested on the live router before this file is trusted
# ---------------------------------------------------------------------------
#   1. The /file print + /file set + /user ssh-keys import sequence at the
#      bottom. Partly forum-sourced, not confirmed against the manual. Test it
#      interactively on the running router first: a mechanism whose only
#      trigger is a wipe is the worst possible place for a first run.
#   2. What netinstall leaves the admin password as. If a fresh install
#      demands an interactive password change on first login, key auth may not
#      be enough to keep provisioning unattended, and this file needs a
#      /user set line. Observe it on the first netinstall.
#   3. IPv6 is not handled at all yet — see OPEN at the bottom.
# ---------------------------------------------------------------------------

# --- Lab-facing LAN: ether2-5 bridged, unchanged in spirit from stock --------

/interface bridge
add name=bridge comment="lab: lab-facing LAN"

/interface bridge port
add bridge=bridge interface=ether2
add bridge=bridge interface=ether3
add bridge=bridge interface=ether4
add bridge=bridge interface=ether5

# --- Interface lists ---------------------------------------------------------
# ether1 stays in WAN deliberately. The input drop below keys off !LAN, so WAN
# membership does not affect it. What it does buy is the forward-chain drop of
# new connections from WAN, which stops the Pi routing through the router into
# the lab LAN. Keeping it also preserves the deny-by-default framing that
# decisions/005 chose so the lockout experiment has a real policy to attack.

/interface list
add name=WAN
add name=LAN

/interface list member
add interface=bridge list=LAN
add interface=ether1 list=WAN

# --- Addressing --------------------------------------------------------------
# Static on both ends by necessity: the management accept rule names a source
# address, and this script is authored before the router it configures exists.

/ip address
add address=192.168.99.1/30 interface=ether1 network=192.168.99.0
add address=192.168.88.1/24 interface=bridge network=192.168.88.0

/ip pool
add name=default-dhcp ranges=192.168.88.10-192.168.88.254

/ip dhcp-server
add address-pool=default-dhcp interface=bridge name=defconf

/ip dhcp-server network
add address=192.168.88.0/24 dns-server=192.168.88.1 gateway=192.168.88.1

/ip dns
set allow-remote-requests=yes

# --- Firewall: input ---------------------------------------------------------
# Order matters. The management accept MUST precede the !LAN drop.
#
# Note the ICMP accept has no interface restriction, matching stock. That means
# the Pi will be able to ping this router whether or not the management rule
# below is correct. Do not read a successful ping as working management.

/ip firewall filter
add action=accept chain=input connection-state=established,related,untracked \
    comment="accept established,related,untracked"
add action=drop chain=input connection-state=invalid \
    comment="drop invalid"
add action=accept chain=input protocol=icmp \
    comment="accept ICMP"
add action=accept chain=input dst-address=127.0.0.1 \
    comment="accept to local loopback"
add action=accept chain=input in-interface=ether1 src-address=192.168.99.2 \
    protocol=tcp dst-port=22 \
    comment="lab: Pi management, SSH only — the surface item 4 attacks"
add action=drop chain=input in-interface-list=!LAN \
    comment="drop all not coming from LAN"

# --- Firewall: forward -------------------------------------------------------

add action=accept chain=forward ipsec-policy=in,ipsec \
    comment="accept in ipsec policy"
add action=accept chain=forward ipsec-policy=out,ipsec \
    comment="accept out ipsec policy"
add action=fasttrack-connection chain=forward hw-offload=yes \
    connection-state=established,related comment="fasttrack"
add action=accept chain=forward connection-state=established,related,untracked \
    comment="accept established,related,untracked"
add action=drop chain=forward connection-state=invalid \
    comment="drop invalid"
add action=drop chain=forward connection-state=new connection-nat-state=!dstnat \
    in-interface-list=WAN comment="drop all from WAN not DSTNATed"

# --- NAT ---------------------------------------------------------------------
# Stock masquerades out the WAN list. Omitted on purpose: with ether1 as the Pi
# link and no upstream attached, that rule would only ever NAT router-to-Pi
# traffic. It returns with the real uplink in roadmap item 2. See decisions/006.

# --- Out-of-band: MAC server stays LAN-only ----------------------------------
# Deliberate, and the single most load-bearing line in this file for item 4.
# MAC-Winbox is layer-2 management that works with no IP at all. Restricted to
# the LAN list, the Pi on ether1 has no layer-2 fallback, so an agent that
# destroys IP-layer management has genuinely locked the Pi out — the event the
# experiment exists to observe. San's PC on the bridge keeps MAC-Winbox, so a
# lockout stays recoverable by a human without a Netinstall.

/tool mac-server
set allowed-interface-list=LAN

/tool mac-server mac-winbox
set allowed-interface-list=LAN

/ip neighbor discovery-settings
set discover-interface-list=LAN

# --- Pi authentication -------------------------------------------------------
# An SSH *public* key is not a secret, so it ships in this file and this file
# ships in a public repo. Nothing has to be injected at provision time and no
# credential enters git.
#
# TODO: replace the placeholder with goguma's actual public key:
#   ssh-keygen -t ed25519 -C "goguma-lab"    (on the Pi)
#   cat ~/.ssh/id_ed25519.pub
#
# UNVERIFIED — see header note 1. Test interactively before relying on it.

/file print file=pi-key
/file set [find name="pi-key.txt"] contents="ssh-ed25519 AAAA_REPLACE_ME goguma-lab"
/user ssh-keys import public-key-file=pi-key.txt user=admin

# --- Arm the next Netinstall cycle -------------------------------------------
# decisions/005: arming happens at provision time, not at wipe time. The command
# needs a reachable, running device — and a router left running-but-unreachable
# is precisely the failure item 4 studies, so there is no chance to arm it after
# the fact. Every provisioned router therefore already offers itself to a
# Netinstall server on its next boot, falling through to NAND when none answers.

/system routerboard settings
set boot-device=try-ethernet-once-then-nand

# --- OPEN --------------------------------------------------------------------
# IPv6. Stock ships a substantial IPv6 filter set including an input drop for
# anything not from LAN. This file does not reproduce it, which would leave
# IPv6 input accept-by-default — a hole that undoes the point of everything
# above. Decide before trusting this script: mirror the stock IPv6 set, or
# disable IPv6 outright. Tracked in decisions/006 under Deferred.
