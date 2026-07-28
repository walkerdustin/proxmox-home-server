# Homelab memory

Working notes for the Proxmox home-server build. Update as hardware/network facts change.

## Current LAN (Smart 3 full router)

| Item | Value |
|------|--------|
| Router | Telekom Speedport Smart 3 (full router mode, not modem) |
| LAN subnet | `192.168.2.0/24` |
| Gateway | `192.168.2.1` |
| Proxmox management | `https://192.168.2.10:8006` |
| Proxmox hostname | `pve` |
| Proxmox version | VE 9.x (Debian trixie), no-subscription repo |

## Host NICs (pve)

Interface **name** = what you use in bridges/`/etc/network/interfaces`.  
**MAC** = stable hardware ID for that RJ45.  
**Altname** = kernel alternate name (here MAC-based `enx…`); same port, different label.  
**PCI** = physical function on the bus (`01:00.0` / `.1` = same I350 card).

| Name | Altname | MAC | PCI | State (typical) | Role |
|------|---------|-----|-----|-----------------|------|
| `nic0` | `enx4ccc6a6de0ed` | `4c:cc:6a:6d:e0:ed` | `0000:03:00.0` | UP | Onboard Realtek — management today (`vmbr0`) |
| `nic1` | `enx98b78524968a` | `98:b7:85:24:96:8a` | `0000:01:00.0` | DOWN | I350 port A |
| `nic2` | `enx98b78524968b` | `98:b7:85:24:96:8b` | `0000:01:00.1` | DOWN | I350 port B |

`vmbr0` currently uses the same MAC as `nic0` (bridge inherits the enslaved NIC MAC).

Physical I350 ports labeled on the chassis with stickers after `ethtool -p nic1` / `ethtool -p nic2` (2026-07-28).

| Name | Sticker on chassis |
|------|--------------------|
| `nic1` | **WAN** (convention in cutover-guide.md) |
| `nic2` | **LAN** (convention in cutover-guide.md) |
| `nic0` | **EMERGENCY** |

See `cutover-guide.md` for the full procedure.

### Planned topology (cutover guide)

| Bridge | NIC | Purpose |
|--------|-----|---------|
| `vmbr0` | `nic2` | LAN + Proxmox management |
| `vmbr1` | `nic1` | WAN (modem; no host IP) |
| `vmbr2` | `nic0` | Emergency backdoor (physically empty) |
| `vmbr3` | virtual only | DMZ (Phase 2) |

## Storage

| Item | Detail |
|------|--------|
| `rpool` | ZFS mirror |
| Disk A | Samsung 850 EVO 250GB — `S2CJNXAG514758J` (`…-part3`) |
| Disk B | Samsung 860 EVO 500GB — `S3Z2NB0KA29651E` (`…-part3`) |
| ESPs | `A0B2-D849` (250GB), `041E-0F11` (500GB) |
| Other disks | HDDs + ~120GB Crucial — unused for now |

## Phase status

- [x] BIOS power/virt settings (MSI Z170-A PRO)
- [x] Proxmox install + no-subscription updates
- [x] `rpool` mirror + both ESPs bootable
- [x] Smart 3 replaces Speedport 7 (full router)
- [ ] OPNsense VM + real bridges (see cutover-guide.md)
- [ ] Smart 3 modem mode + OPNsense WAN cutover
- [ ] Phase 2 apps (Dockploy, Seafile)
