# netops-lab: the hEX side of OSPF and eBGP with FRR on the Pi. decisions/010.
#
# NOT YET APPLIED TO HARDWARE (2026-09-30). Syntax is RouterOS v7, checked
# against the MikroTik manual for 7.20 (explicit /routing bgp instance). The
# run sheet is docs/frr-bringup.md.
#
# Apply from goguma, after provisioning/frr-install.sh ran on the Pi:
#
#     scp provisioning/frr-router.rsc lab-router:
#     ssh lab-router "/import file-name=frr-router.rsc verbose=yes"
#
# Remove with provisioning/frr-router-remove.rsc (same two commands).
#
# This file is NOT part of default-config.rsc. A wipe (reprovision.sh) removes
# all of it, and you apply it again after the wipe. decisions/010 says why.
#
# Idempotent: the first block removes every item this file adds, so a second
# import gives the same result as the first. Every item carries the name or
# comment prefix "lab-frr", and the remove block finds items only by that
# prefix. It does not touch the ether1 address, the SSH accept, or any other
# rule from default-config.rsc (decisions/006).
#
# Topology this assumes (default-config.rsc):
#   ether1   192.168.99.1/30   point-to-point link to the Pi (.2)
#   bridge   192.168.88.1/24   lab LAN
#   ether5   house uplink      DHCP client. NOT in OSPF, NOT in BGP.
#   lo       10.255.0.1/32     router ID, added below

# --- Remove what a previous import added --------------------------------------
# KEEP THIS BLOCK THE SAME AS frr-router-remove.rsc.

/routing bgp connection remove [find name="lab-frr-pi"]
/routing bgp instance remove [find name="lab-frr"]
/routing ospf interface-template remove [find comment~"^lab-frr"]
/routing ospf area remove [find name="lab-frr-backbone"]
/routing ospf instance remove [find name="lab-frr"]
/routing filter rule remove [find comment~"^lab-frr"]
/ip firewall filter remove [find comment~"^lab-frr"]
/ip address remove [find comment~"^lab-frr"]

# --- Router ID on lo -----------------------------------------------------------
# A /32 on the loopback. OSPF carries it to the Pi, and the Pi can ping it.

/ip address
add address=10.255.0.1/32 interface=lo comment="lab-frr: router ID (decisions/010)"

# --- Firewall: accept OSPF and BGP from the Pi only ------------------------------
# ether1 is not in the LAN list, so the "drop all not coming from LAN" rule
# drops OSPF (IP protocol 89) and BGP (TCP 179) from the Pi. These two accepts
# go above that drop. They use the same three matches as the SSH accept in
# default-config.rsc: in-interface, source address, and protocol.
#
# If the find returns nothing (the drop rule comment changed), the import stops
# here with an error. That is the safe failure: no routing starts, and the
# existing rules do not change.
#
# These rules only accept. They cannot remove access to the router.

/ip firewall filter
add action=accept chain=input in-interface=ether1 src-address=192.168.99.2 \
    protocol=ospf \
    comment="lab-frr: OSPF from the Pi (decisions/010)" \
    place-before=[find where chain=input comment="drop all not coming from LAN"]
add action=accept chain=input in-interface=ether1 src-address=192.168.99.2 \
    protocol=tcp dst-port=179 \
    comment="lab-frr: BGP from the Pi (decisions/010)" \
    place-before=[find where chain=input comment="drop all not coming from LAN"]

# --- Routing filters -------------------------------------------------------------
# Allow-lists. A route that no rule accepts is rejected, and the last rule in
# each chain says so explicitly.
#
# frr-ospf-in:  only /32 host routes in 10.255.0.0/16 (the Pi router ID).
# frr-bgp-in:   only /32 host routes in 10.255.1.0/24 (the Pi service prefix).
# frr-bgp-out:  nothing. The router sends no BGP routes to the Pi. So the Pi
#               cannot learn a default route, or any other route, from BGP.

/routing filter rule
add chain=frr-ospf-in rule="if (dst in 10.255.0.0/16 && dst-len == 32) { accept }" \
    comment="lab-frr: OSPF in, Pi loopbacks only"
add chain=frr-ospf-in rule="reject" comment="lab-frr: OSPF in, reject the rest"
add chain=frr-bgp-in rule="if (dst in 10.255.1.0/24 && dst-len == 32) { accept }" \
    comment="lab-frr: BGP in, Pi service prefixes only"
add chain=frr-bgp-in rule="reject" comment="lab-frr: BGP in, reject the rest"
add chain=frr-bgp-out rule="reject" comment="lab-frr: BGP out, send nothing"

# --- OSPF ------------------------------------------------------------------------
# Area 0 on the ether1 link. ptp matches "ip ospf network point-to-point" on
# the Pi. Hello 10s and dead 40s are the defaults on both sides, and are
# written here because a mismatch stops the adjacency.
#
# lo and bridge are passive: OSPF advertises their prefixes but sends no hellos
# there. A passive bridge also means a host on the lab LAN cannot form an
# adjacency and inject routes.
#
# originate-default=never and no redistribute: the router does NOT send a
# default route, and it does not send the ether5 house subnet. decisions/010.

/routing ospf instance
add name=lab-frr version=2 router-id=10.255.0.1 originate-default=never \
    in-filter-chain=frr-ospf-in comment="lab-frr: decisions/010"

/routing ospf area
add name=lab-frr-backbone area-id=0.0.0.0 instance=lab-frr \
    comment="lab-frr: area 0"

/routing ospf interface-template
add area=lab-frr-backbone interfaces=ether1 type=ptp \
    hello-interval=10s dead-interval=40s \
    comment="lab-frr: link to the Pi"
add area=lab-frr-backbone interfaces=lo passive \
    comment="lab-frr: router ID"
add area=lab-frr-backbone interfaces=bridge passive \
    comment="lab-frr: lab LAN"

# --- eBGP ------------------------------------------------------------------------
# Private ASNs (RFC 6996): the hEX is 65001, the Pi is 65002.
#
# connect=no listen=yes: the router only waits for the Pi. The Pi bgpd runs
# with "-p 0" and has no listener, so exactly one side opens the session.
#
# RouterOS 7.20 and later need an explicit BGP instance.

/routing bgp instance
add name=lab-frr as=65001 router-id=10.255.0.1

/routing bgp connection
add name=lab-frr-pi instance=lab-frr local.role=ebgp \
    local.address=192.168.99.1 remote.address=192.168.99.2 remote.as=65002 \
    connect=no listen=yes \
    input.filter=frr-bgp-in output.filter-chain=frr-bgp-out \
    comment="lab-frr: eBGP to the Pi (decisions/010)"
