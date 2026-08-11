# Homelab memory

Working notes for the Proxmox home-server build. Update as hardware/network facts change.

**Last verified:** 2026-08-11 — Host RAM upgraded to 32 GB (usable ~31.2 GiB); OPNsense PPPoE + Smart 3 modem mode still production.

## Current production topology

```text
[TAE/DSL] -- [Smart 3 MODEM LAN4] --WAN-- [nic1 / vmbr1]
                                              |
                                    OPNsense: VLAN7 → PPPoE → WAN
                                              |
                              OPNsense LAN 192.168.1.1 (vtnet1 / vmbr0)
                                              |
[House / UniFi AP / PoE switch] ----LAN-- [nic2 / vmbr0] -- Proxmox 192.168.1.10
                                              |
[Laptop only when broken] ---------- [nic0 / vmbr2 10.99.99.1]
```

| Item | Value |
|------|--------|
| Edge | Telekom Speedport Smart 3 in **DSL modem mode** |
| Modem cable | Smart 3 **LAN 4** → Proxmox `nic1` (WAN sticker) |
| Modem status UI | `http://169.254.2.1` from Smart 3 LAN 1–3 only (read-only) |
| House LAN subnet | `192.168.1.0/24` |
| OPNsense LAN | `192.168.1.1/24` (DHCP server on) |
| DHCP pool | `192.168.1.100`–`192.168.1.200` |
| Proxmox management | `https://192.168.1.10:8006` |
| OPNsense GUI | `https://192.168.1.1` |
| Wi‑Fi | UniFi U7 on PoE switch behind OPNsense (Smart 3 Wi‑Fi off) |
| Proxmox hostname | `pve` |
| Proxmox version | VE 8.2.x (no-subscription repo); kernel `7.0.14-*-pve` |
| Host RAM | **32 GB** DDR4 (4×8 GB mixed: 2× Kingston KHX2666 + 2× Corsair 2133); running **JEDEC 2133 MT/s** |
| Host CPU | Intel Core i5-6600K (4c/4t) |
| OPNsense version | 26.7.x in VM 100 (`opnsense`), **Start at boot = Yes**, RAM **3072 MB** |

### OPNsense WAN stack (critical)

| Layer | Device | Notes |
|-------|--------|--------|
| Physical / VirtIO | `vtnet0` → Proxmox `vmbr1` / `nic1` | No host IP on `vmbr1` |
| VLAN | `vlan01` tag **7** parent `vtnet0` | Must **Apply** after create or it may not exist at runtime |
| PPPoE | `pppoe0` on `vlan01` | Telekom username format `Anschlusskennung#Zugangsnummer@t-online.de` |
| Assigned WAN | `pppoe0` | Block private + bogon **on**; IPv6 None for now |

LAN: `vtnet1` → `vmbr0` / `nic2`.

## Host NICs (pve)

| Name | Altname | MAC | PCI | Role |
|------|---------|-----|-----|------|
| `nic0` | `enx4ccc6a6de0ed` | `4c:cc:6a:6d:e0:ed` | `0000:03:00.0` | EMERGENCY → `vmbr2` `10.99.99.1/24` (cable empty) |
| `nic1` | `enx98b78524968a` | `98:b7:85:24:96:8a` | `0000:01:00.0` | WAN → `vmbr1` (no Proxmox IP) |
| `nic2` | `enx98b78524968b` | `98:b7:85:24:96:8b` | `0000:01:00.1` | LAN → `vmbr0` `192.168.1.10/24` gw `192.168.1.1` |

| Sticker | Interface |
|---------|-----------|
| **WAN** | `nic1` |
| **LAN** | `nic2` |
| **EMERGENCY** | `nic0` |

| Bridge | Port | Host IP |
|--------|------|---------|
| `vmbr0` | `nic2` | `192.168.1.10/24`, gateway `192.168.1.1` |
| `vmbr1` | `nic1` | none |
| `vmbr2` | `nic0` | `10.99.99.1/24` |
| `vmbr3` | none | DMZ Phase 2 |

## Storage

| Item | Detail |
|------|--------|
| `rpool` | ZFS mirror |
| Disk A | Samsung 850 EVO 250GB — `S2CJNXAG514758J` (`…-part3`) |
| Disk B | Samsung 860 EVO 500GB — `S3Z2NB0KA29651E` (`…-part3`) |
| ESPs | `A0B2-D849` (250GB), `041E-0F11` (500GB) |
| Other disks | HDDs + ~120GB Crucial — unused for now |

## Recovery notes (learned the hard way)

- Prefer an **admin-capable** PC for temporary static IPs during migrations; locked corporate laptops cannot set static IPs.
- Idle I350 ports may show `DOWN` until `ip link set nicX up` (admin up) before link lights appear.
- Overlapping addresses during LAN move: Proxmox temporary `192.168.1.10` while still on `.2.10`; admin PC both `.2.x` and `.1.x`.
- Isolate the downstream PoE switch **before** enabling OPNsense DHCP so two DHCP servers never share L2.
- Smart 3 modem rollback requires **factory reset + restore** of saved config (not a simple toggle).
- OPNsense XML backups contain secrets — keep them private; do not commit.

## Guides

| File | Role |
|------|------|
| [`opnsense-rebuild-guide.md`](opnsense-rebuild-guide.md) | **Authoritative** rebuild / cutover from scratch (double NAT → modem) |
| [`cutover-guide.md`](cutover-guide.md) | Historical Stage 0–4 notes; Stage 5 superseded |

## Phase status

- [x] BIOS power/virt settings (MSI Z170-A PRO)
- [x] Proxmox install + no-subscription updates
- [x] `rpool` mirror + both ESPs bootable
- [x] Bridges `vmbr0`–`vmbr3`; LAN on `nic2`; emergency on `nic0`
- [x] OPNsense VM installed (UFS), dual NIC, PPPoE + VLAN 7
- [x] UniFi U7 behind OPNsense; Smart 3 Wi‑Fi off
- [x] Smart 3 modem mode + OPNsense as edge router
- [x] Host RAM 32 GB installed (Phase 1 hardware complete)
- [ ] Phase 2 apps (Dockploy, Seafile, DMZ, HAProxy/SNI); consider ZFS ARC cap ~4 GB when HDD pool is in use
