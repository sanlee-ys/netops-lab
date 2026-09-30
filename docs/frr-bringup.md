# FRR bring-up run sheet (roadmap item 3)

This is the owner's run sheet for OSPF and eBGP between the Pi (`goguma`) and
the hEX. The decision and its reasons are in
[decisions/010](../decisions/010-frr-on-the-pi.md). This file tells you what
to run and in which order.

**Status on 2026-09-30:** the configs and scripts are in the repo. Nothing is
applied to the Pi or to the router. The shell scripts pass `bash -n` and
shellcheck. No step below has run on hardware yet.

Where each command runs:

| Prompt | Machine |
|---|---|
| `goguma$` | the Pi, from `~/netops-lab`. Reach it from the PC with `ssh sanlee@goguma`. |
| `ssh lab-router "..."` | the hEX, sent from the Pi. The `lab-router` SSH alias is in `docs/bring-up-notes.md`. |

The files:

| File | Runs on |
|---|---|
| `frr/daemons`, `frr/frr.conf` | Pi, copied to `/etc/frr` by the install script |
| `provisioning/frr-router.rsc` | hEX, apply |
| `provisioning/frr-router-remove.rsc` | hEX, rollback |
| `provisioning/frr-install.sh` | Pi, install and route guard |
| `provisioning/frr-verify.sh` | Pi, check |

---

## Values the owner fills or confirms

No config file holds a placeholder. Each value below is either from the
bring-up notes or chosen in decisions/010. Confirm each one before step 1.
If a value is different on the hardware, change it in every file in the
"Set in" column, in one commit.

| Value | Repo value | Set in | Confirm with |
|---|---|---|---|
| Pi lab interface | `eth0` | `frr/frr.conf`, `LAB_IFACE` in both scripts | `goguma$ ip -br link` |
| Pi lab address | `192.168.99.2/30` | NetworkManager connection `lab`; `LAB_ADDR` in `frr-install.sh`; both `.rsc` files | `goguma$ ip -br -4 addr show dev eth0` |
| hEX ether1 address | `192.168.99.1/30` | `default-config.rsc`; `frr/frr.conf`; `ROUTER_LINK_ADDR` in `frr-verify.sh` | `ssh lab-router "/ip address print"` |
| hEX input drop comment | `drop all not coming from LAN` | `frr-router.rsc` (the `place-before` find) | `ssh lab-router "/ip firewall filter print where chain=input"` |
| RouterOS version | 7.20.8 (7.20 or later is necessary for `/routing bgp instance`) | `frr-router.rsc` | `ssh lab-router "/system resource print"` |
| Loopback range | `10.255.0.0/16` | `frr/frr.conf`, `frr-router.rsc` | `goguma$ ip -4 route`: no route in `10.255.0.0/16` before step 3 |
| ASNs | hEX `65001`, Pi `65002` | `frr/frr.conf`, `frr-router.rsc` | Chosen. Change both files together. |
| Pi host firewall | no firewall, or one that accepts IP protocol 89 and TCP 179 on `eth0` | not in the repo | `goguma$ sudo nft list ruleset` |
| House LAN on wlan0 | `192.168.1.0/24` (the ether5 lease in the bring-up notes) | not in any config; FIB-GUARD blocks it | `goguma$ ip -4 route show dev wlan0` |
| WireGuard client `AllowedIPs` | does not include `10.255.0.0/16` | PC WireGuard client | Optional. Add it only if you want to reach the loopbacks over the tunnel. |

---

## Self-lockout: which step can cut you off, and the guard

This repo exists to study self-lockout, so read this before step 1.

**Step 4 can cut you off.** When FRR starts on the Pi, it installs OSPF and
BGP routes in the kernel. If a default route, or a route to the house LAN,
arrived via `eth0`, the Pi would send that traffic to the hEX. The hEX drops
new connections from ether1 (the forward drop in `default-config.rsc`). The
Pi would lose its internet path, and a route to the house LAN would cut the
SSH session from the PC.

There are three guards, in this order:

1. **FIB-GUARD in `frr/frr.conf`.** zebra installs only `10.255.0.0/16` host
   routes and `192.168.88.0/24`. A default route or a house-LAN route never
   reaches the kernel. This guard is always on, also after a reboot.
2. **The route guard in `frr-install.sh`.** After it restarts FRR, it
   watches the default route for 90 seconds. If the route moves to `eth0`, it
   stops FRR and flushes the OSPF and BGP kernel routes.
3. **Check 4 in `frr-verify.sh`.** It fails when a default route is via
   `eth0`. Run it after every change.

The router cannot learn a default route from the Pi in a way that matters.
Its own default route from DHCP on ether5 has a lower distance than OSPF or
BGP, and its input filters accept only `10.255.0.0/16` host routes.

**Step 3 cannot cut you off.** `frr-router.rsc` adds only accept rules and
routing config. If it cannot find the drop rule, the import stops at that
line, before the firewall rules and the routing config.

**The rollback must not cut you off.** Never run `nmcli con down lab`, never
remove `192.168.99.1/30` or `192.168.99.2/30`, and never remove the SSH accept
on the hEX. The management path on ether1 does not depend on FRR
([decisions/006](../decisions/006-management-surface-on-ether1.md)).

**Physical fallback.** If the Pi becomes unreachable after step 4, pull the
cable from the hEX ether1. All OSPF and BGP routes on the Pi go through
`eth0`, so they go away with the link, and wlan0 carries all traffic again.
Then do the Pi half of the rollback over wlan0. Do not only reboot the Pi:
FRR is enabled and starts again.

Keep one SSH session to `goguma` open over wlan0 for all of the steps.

---

## Steps

### 0. Get the files onto the Pi

Files go from the PC to the Pi by `git pull`, not by `scp` (see `CLAUDE.md`).

```bash
goguma$ cd ~/netops-lab
goguma$ git pull
```

Now check that the files arrived:

```bash
goguma$ ls frr provisioning/frr-*
```

### 1. Record the state before the change

```bash
goguma$ ip -4 route show default
ssh lab-router "/ip firewall filter print where chain=input"
```

Now keep this output. The default route must show `dev wlan0`. The rollback
must give the same two outputs again.

### 2. Dry run on the Pi

```bash
goguma$ sudo ./provisioning/frr-install.sh --dry-run
```

Now read the plan. Each `[dry-run]` line is a change that step 4 makes. The
last line must be `frr-install: dry run complete; nothing changed`. If a
preflight check fails, fix it before you continue.

### 3. Apply the router side

Apply the router first. With no FRR on the Pi yet, OSPF sends hellos to
nothing and BGP waits. Nothing changes for traffic. Then, in step 4, all
routes arrive while the install route guard watches.

```bash
goguma$ scp provisioning/frr-router.rsc lab-router:
ssh lab-router "/import file-name=frr-router.rsc verbose=yes"
```

Now check that management is still up, and that the new accepts are above the
drop:

```bash
ssh lab-router "/system resource print"
ssh lab-router "/ip firewall filter print where chain=input"
ssh lab-router "/routing ospf interface-template print"
```

The two `lab-frr:` rules must have a lower number than
`drop all not coming from LAN`.

### 4. Install and start FRR on the Pi

This is the step that can cut you off. Read the self-lockout section first.

```bash
goguma$ sudo ./provisioning/frr-install.sh
```

The script watches the default route for 90 seconds after the restart. The
last line must be `route guard passed`.

Now check the result:

```bash
goguma$ sudo ./provisioning/frr-verify.sh
```

It must end with `frr-verify: all checks passed`. Exit status 1 means that a
check failed. Exit status 2 means that the script could not run.

### 5. Check from both ends

From the Pi to the router loopback, over the OSPF route:

```bash
goguma$ ping -c 3 10.255.0.1
```

From the router to the Pi service prefix, over the BGP route:

```bash
ssh lab-router "/routing ospf neighbor print"
ssh lab-router "/routing bgp session print"
ssh lab-router "/ip route print where dst-address in 10.255.0.0/16"
ssh lab-router "/ping 10.255.1.1 count=3"
```

Now confirm that the default route did not move:

```bash
goguma$ ip -4 route show default
```

It must be the same as in step 1.

### 6. Record the result

Add a dated entry to [bring-up-notes.md](bring-up-notes.md) with what you saw.
Then change the status of decisions/010 from `Proposed` to `Accepted`, and
change roadmap item 3 in the README.

---

## After a wipe

`reprovision.sh` removes the router side, because it is not in
`default-config.rsc`. FRR on the Pi keeps running, but it has no neighbor.
`frr-verify.sh` then fails checks 1 to 3. That is expected.

Apply the router side again (step 3), then check:

```bash
goguma$ sudo ./provisioning/frr-verify.sh
```

---

## Rollback

Do the Pi first, then the router. When FRR stops, zebra removes its kernel
routes, so the Pi goes back to wlan0 only. Then the router side can go.

Neither half touches the ether1 address, the `lab` connection, or the SSH
accept. The management path stays up for all of the rollback.

### Pi

```bash
goguma$ sudo systemctl stop frr
goguma$ sudo systemctl disable frr
goguma$ sudo ip -4 route flush proto ospf
goguma$ sudo ip -4 route flush proto bgp
goguma$ sudo ip addr del 10.255.0.2/32 dev lo
goguma$ sudo ip addr del 10.255.1.1/32 dev lo
```

The two `flush` commands do nothing when zebra already removed its routes.
An `ip addr del` error that says the address is not there is also safe.

Now check that the Pi is back to its baseline:

```bash
goguma$ ip -4 route show default
ssh lab-router "/system resource print"
```

The default route must show `dev wlan0`, as in step 1. The router must answer.

To put back the package config files as well (optional):

```bash
goguma$ sudo cp -p /etc/frr/daemons.netops-lab.orig /etc/frr/daemons
goguma$ sudo cp -p /etc/frr/frr.conf.netops-lab.orig /etc/frr/frr.conf
```

Now check that the copies are in place:

```bash
goguma$ sudo grep -E '^(bgpd|ospfd)=' /etc/frr/daemons
```

Both lines must say `=no`.

### Router

```bash
goguma$ scp provisioning/frr-router-remove.rsc lab-router:
ssh lab-router "/import file-name=frr-router-remove.rsc verbose=yes"
```

Now check that only the lab-frr items went away:

```bash
ssh lab-router "/ip firewall filter print where chain=input"
ssh lab-router "/routing ospf instance print"
ssh lab-router "/system resource print"
```

The input chain must be the same as in step 1. The SSH accept from
`192.168.99.2` must still be there. The router must answer.

### If the install route guard stopped FRR

The guard already stopped FRR and flushed its routes. Confirm it:

```bash
goguma$ ip -4 route show default
goguma$ systemctl is-active frr
```

The default route must show `dev wlan0`, and FRR must be `inactive`. Then
find which route came through. Read `FIB-GUARD` in `frr/frr.conf` and the
router filters in `frr-router.rsc` before you start FRR again.

---

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| No OSPF neighbor on either side | The hEX drops OSPF: the accept is missing or below the `!LAN` drop | `ssh lab-router "/ip firewall filter print stats where chain=input"` |
| OSPF stays in `Init` or `2-Way` | Hello, dead, or network type differs | `goguma$ sudo vtysh -c "show ip ospf interface eth0"` and `ssh lab-router "/routing ospf interface print detail"` |
| OSPF stays in `ExStart` or `Exchange` | MTU differs | `goguma$ ip link show eth0` and `ssh lab-router "/interface print detail where name=ether1"` |
| OSPF is `Full`, but check 3 fails | FIB-GUARD blocks the route, or the hEX lo address is missing | `goguma$ sudo vtysh -c "show ip route 10.255.0.1"` |
| BGP stays in `Active` or `Connect` on the Pi | The hEX drops TCP 179, or the ASN or address differs | `ssh lab-router "/routing bgp connection print detail"` and `goguma$ sudo vtysh -c "show bgp neighbors 192.168.99.1"` |
| BGP is `Established`, but the hEX has no `10.255.1.1/32` | The Pi export route-map or the hEX `frr-bgp-in` filter | `goguma$ sudo vtysh -c "show bgp ipv4 unicast neighbors 192.168.99.1 advertised-routes"` and `ssh lab-router "/routing route print where bgp"` |
| `/import` stops at `place-before` | The drop rule comment on this board is different | `ssh lab-router "/ip firewall filter print where chain=input"`, then change the find in `frr-router.rsc` |
| `/import` stops with `expected end of command` | A property name differs on this RouterOS version | Compare the failed line with the MikroTik manual for the installed version |
| `frr-install.sh` stops at `vtysh --dryrun` | A command in `frr.conf` that the installed FRR version does not know | `goguma$ sudo vtysh --dryrun -f frr/frr.conf` shows the line |

A successful `ping` from the Pi to `192.168.99.1` proves nothing about OSPF or
BGP. The hEX accepts ICMP on every interface, and the connected `/30` needs no
routing protocol. Use `frr-verify.sh`.
