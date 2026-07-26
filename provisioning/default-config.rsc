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
# Verification status — read before trusting any of this
# ---------------------------------------------------------------------------
#   1. The /file print + /file set + /user ssh-keys import sequence near the
#      bottom was run interactively on the live router (7.20.8, 2026-07-25) and
#      works: /user ssh-keys print showed the key attached to admin with the -C
#      comment carried through as key-owner.
#
#      Precisely what that does and does not establish: the COMMANDS work at an
#      interactive prompt. It has NOT been shown that /file print file= behaves
#      the same inside a default-configuration script at first boot, which is a
#      different execution context. Confirm on the first netinstall.
#
#   2. The `-r -s` combination in the install line above is not confirmed. `-r`
#      is documented as "reinstall with default configuration script" and `-s`
#      installs a custom one; whether -s implies -r, requires it, or conflicts
#      with it is unread. Check before the first run.
#
#   3. What netinstall leaves the admin password as. If a fresh install demands
#      an interactive password change on first login, key auth may not be enough
#      to keep provisioning unattended, and this file needs a /user set line.
#
#   4. The IPv6 input guard is written from the stock rules but has not been
#      applied to a device.
#
#   5. The file as a whole has never been applied to anything.
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
#
# Note what is NOT here: stock puts a DHCP *client* on ether1, waiting for an
# upstream lease. The thing on ether1 is the Pi, which will never serve one, so
# the client is dropped rather than left to retry forever. This is why ether1
# had no address at all on the factory config.

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
# The menu path is repeated rather than relying on the context set above. A
# comment block does not reset it, so these would attach correctly either way,
# but an implicit dependency on where the cursor happens to be is not something
# to leave in a file whose failure mode is an unreachable router.

/ip firewall filter
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

# --- Firewall: IPv6 input ----------------------------------------------------
# This closes a back door, and it is the same back door MAC-Winbox was.
#
# RouterOS brings up link-local IPv6 automatically. Without a v6 filter, input
# is accept-by-default, so an agent could destroy every IPv4 management path
# above and the Pi would still reach this router over IPv6 link-local on
# ether1. That would not break item 4 visibly — it would quietly invalidate it.
#
# Note what is deliberately absent: there is NO v6 equivalent of the ether1
# management accept. IPv6 is filtered and reachable-for-diagnostics, but it is
# not a management path. The Pi's only way in is the single IPv4 SSH rule.
#
# ICMPv6 is accepted because v6 genuinely depends on it (neighbour discovery,
# path MTU); dropping it produces confusing half-broken behaviour rather than
# clean denial. Same caveat as ICMP above: a successful v6 ping proves nothing
# about management.
#
# Scope accepted knowingly (decisions/006): this is an input guard only. The v6
# forward chain stays accept-by-default. Low risk here because the router has
# no IPv6 upstream and no v6 addressing beyond link-local, so there is nothing
# to forward — but it is a gap, not an oversight, and it is written down.

/ipv6 firewall filter
add action=accept chain=input connection-state=established,related,untracked \
    comment="accept established,related,untracked"
add action=drop chain=input connection-state=invalid \
    comment="drop invalid"
add action=accept chain=input protocol=icmpv6 \
    comment="accept ICMPv6"
add action=drop chain=input in-interface-list=!LAN \
    comment="drop everything else not coming from LAN"

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
# Key generated on goguma with: ssh-keygen -t ed25519 -C "goguma-lab"
#
# The three lines below are VERIFIED on 7.20.8 — see header note 1. Note the
# extension: `file print file=pi-key` creates pi-key.txt, which is the name
# both following lines must reference.

/file print file=pi-key
/file set [find name="pi-key.txt"] contents="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZ93ZTGZl9yxO715yaNraiEhzMDuRJJrQEgc26a8k4t goguma-lab"
/user ssh-keys import public-key-file=pi-key.txt user=admin

# Key-only authentication, stated explicitly rather than inherited from a
# default. The provisioned baseline should not be ambiguous about the one path
# into this router — ambiguity in the management path is what decisions/006
# exists to remove.
#
# ORDER MATTERS: this must follow the import above. Disabling password login
# before a working key is attached is a self-lockout, which would be a poor way
# to begin a lab about self-lockout.
#
# If the key is ever lost, recovery is Netinstall — the harness this lab is
# building anyway, rather than a disaster.

/ip ssh
set always-allow-password-login=no

# --- Arm the next Netinstall cycle -------------------------------------------
# decisions/005: arming happens at provision time, not at wipe time. The command
# needs a reachable, running device — and a router left running-but-unreachable
# is precisely the failure item 4 studies, so there is no chance to arm it after
# the fact. Every provisioned router therefore already offers itself to a
# Netinstall server on its next boot, falling through to NAND when none answers.

/system routerboard settings
set boot-device=try-ethernet-once-then-nand

# --- OPEN --------------------------------------------------------------------
# See the "Verification status" block at the top of this file. Nothing below
# the ssh-key sequence has been exercised anywhere, and that sequence has only
# been exercised at an interactive prompt, not in a first-boot context.
