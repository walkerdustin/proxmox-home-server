---
name: opnsense-proxmox-part-2
overview: Create a replacement cutover guide that first establishes and proves a recoverable double-NAT topology, then performs the Smart 3 modem/PPPoE cutover as a separate change. The guide will avoid dependence on the locked laptop’s static-IP settings and use the available wired admin device and local Proxmox console as recovery paths.
todos:
  - id: draft-new-guide
    content: Create the Part 2 guide with current state, double-NAT migration, checkpoints, and recovery steps
    status: in_progress
  - id: add-pppoe-cutover
    content: Document VLAN 7 PPPoE staging, Smart 3 LAN 4 modem cutover, and exact verification gates
    status: pending
  - id: add-rollback-reference
    content: Add factory-reset/restore rollback, troubleshooting branches, topology, and quick reference
    status: pending
isProject: false
---

# OPNsense on Proxmox Setup — Part 2

## Deliverable
Create [`opnsense-proxmox-setup-part-2.md`](opnsense-proxmox-setup-part-2.md) as the new authoritative continuation of [`cutover-guide.md`](cutover-guide.md). Preserve the old guide as historical context; explicitly state that its Stage 5 is superseded.

## Starting state and safety rules
- Record the verified current state: Smart 3 router/DHCP at `192.168.2.1`; Proxmox at `192.168.2.10` on `vmbr0`/`nic2`; OPNsense LAN at `192.168.2.20`; PPPoE device created; Smart 3 Wi-Fi off; UniFi AP and PoE switch currently behind Smart 3.
- Record final mappings: `nic1`/`vmbr1` WAN, `nic2`/`vmbr0` LAN, `nic0`/`vmbr2` emergency.
- Require a wired admin-capable device and local Proxmox keyboard/monitor for the transition. Do not rely on the locked laptop’s static-IP capability or an SSH tunnel.
- Put a backup, verification, stop condition, and rollback directly beside every disruptive operation.

## Phase 1 — Back up and prepare without outage
- Export OPNsense configuration, Smart 3 configuration, and `/etc/network/interfaces`; verify local-console login and VM console access.
- Keep `nic1` unplugged while changing OPNsense WAN from the staged PPPoE assignment to raw `vtnet0` with DHCP for temporary double NAT.
- Uncheck “block private networks” on WAN during double NAT; retain normal firewall/NAT defaults.
- Preserve PPPoE credentials without writing secrets into the guide.

## Phase 2 — Build an isolated final LAN
- Disconnect the PoE switch uplink from Smart 3 and connect the AP, `nic2`, and wired admin device to that isolated switch.
- Give the admin device temporary `192.168.2.x` addressing so both `192.168.2.10` and `192.168.2.20` remain reachable before any subnet change.
- Add a temporary runtime `192.168.1.10/24` address to Proxmox `vmbr0` as a recovery bridge between old and new management addressing.
- Change OPNsense LAN to `192.168.1.1/24`, enable DHCP for `192.168.1.100–192.168.1.200`, and verify the admin device receives a `.1.x` lease.
- Verify OPNsense at `192.168.1.1` and Proxmox at temporary `192.168.1.10`, then persist Proxmox management as `192.168.1.10/24` with gateway `192.168.1.1`.
- Include explicit recovery branches for failure before and after each address change.

## Phase 3 — Enable and prove double NAT
- Connect a normal Smart 3 LAN port to Proxmox `nic1`; OPNsense WAN should receive a `192.168.2.x` DHCP lease while its LAN remains `192.168.1.0/24`.
- Verify gateway, DNS, outbound NAT, internet access, Proxmox/OPNsense management, AP DHCP migration, Wi-Fi, and client isolation from the WAN side.
- Perform OPNsense firmware updates only after this internet path works, then export a fresh configuration backup.
- Require a 24–48 hour soak test before modem mode. Explain expected double-NAT limitations such as inbound forwarding and some gaming/VPN behavior.

## Phase 4 — Stage Telekom PPPoE correctly
- Follow current OPNsense device order: `vtnet0` → VLAN 7 → PPPoE device → WAN assignment.
- Create VLAN 7 and attach the existing PPPoE device to it while leaving the working DHCP WAN assigned during the soak period.
- Validate the Telekom username format against the customer letter without reproducing credentials in screenshots or documentation.
- Cite the official OPNsense PPPoE guide and Telekom Smart 3 manual.

## Phase 5 — Small final modem cutover
- Back up Smart 3 immediately before modem mode and state clearly that modem mode disables routing, Wi-Fi, firewall, and telephony; telephony is not needed here.
- Correct the old guide: modem output is specifically Smart 3 **LAN 4**; LAN 1–3 only expose read-only status at `169.254.2.1`.
- Switch Smart 3 to DSL modem mode, keep the entire downstream `192.168.1.0/24` LAN unchanged, and change only OPNsense WAN from DHCP/`vtnet0` to the prepared PPPoE/VLAN-7 device.
- Verify PPPoE session, public WAN address, default route, DNS, internet, AP/Wi-Fi, and both management UIs before declaring success.

## Rollback and completion
- Make rollback restore the already-proven double-NAT state without changing LAN, AP, DHCP, or Proxmox addresses.
- Document the official Smart 3 rollback requirement: factory-reset it to leave modem mode, restore the saved configuration, reconnect OPNsense WAN to a normal Smart 3 LAN port, and assign WAN back to `vtnet0` DHCP.
- End with concise “stop here and report” diagnostics for link failure, no DHCP lease, no PPPoE discovery, authentication failure, and DNS-only failure.
- Add a final topology diagram and a one-page cable/IP quick reference.