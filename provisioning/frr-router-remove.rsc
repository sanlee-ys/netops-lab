# netops-lab — remove the hEX side of OSPF and eBGP. decisions/010.
#
# NOT YET APPLIED TO HARDWARE (2026-09-30). Rollback step in docs/frr-bringup.md.
#
# Run from goguma:
#
#     scp provisioning/frr-router-remove.rsc lab-router:
#     ssh lab-router "/import file-name=frr-router-remove.rsc verbose=yes"
#
# It removes only items with the name or comment prefix "lab-frr". It does not
# touch the ether1 address, the Pi SSH accept, the "drop all not coming from
# LAN" rule, or anything else from default-config.rsc. So the management path
# from the Pi stays up during and after the rollback (decisions/006).
#
# Safe to run when nothing is applied: each find returns an empty list, and
# remove on an empty list does nothing.
#
# KEEP THIS BLOCK THE SAME AS THE FIRST BLOCK IN frr-router.rsc.

/routing bgp connection remove [find name="lab-frr-pi"]
/routing bgp instance remove [find name="lab-frr"]
/routing ospf interface-template remove [find comment~"^lab-frr"]
/routing ospf area remove [find name="lab-frr-backbone"]
/routing ospf instance remove [find name="lab-frr"]
/routing filter rule remove [find comment~"^lab-frr"]
/ip firewall filter remove [find comment~"^lab-frr"]
/ip address remove [find comment~"^lab-frr"]
