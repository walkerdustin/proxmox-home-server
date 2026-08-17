# Homelab memory

Working notes for the Proxmox home-server build. Update as hardware/network facts change.

**Last verified:** 2026-08-17 — DMZ up; **Seafile 13 CE** public at `https://cloud.dustinwalker.de` (HAProxy → Caddy). oCIS was replaced on the same VM 2026-08-17; the ingress model survived unchanged. Component docs: [`homelab-components/`](homelab-components/).

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
| OPNsense GUI | `https://192.168.1.1:8443` (LAN only; port moved for HAProxy) |
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
| `vmbr3` | none | DMZ — OPNsense `vtnet2` `10.10.10.1/24`; Seafile VM 101 `10.10.10.10` |

## Storage

| Item | Detail |
|------|--------|
| `rpool` | ZFS mirror |
| Disk A | Samsung 850 EVO 250GB — `S2CJNXAG514758J` (`…-part3`) |
| Disk B | Samsung 860 EVO 500GB — `S3Z2NB0KA29651E` (`…-part3`) |
| ESPs | `A0B2-D849` (250GB), `041E-0F11` (500GB) |
| `tank` | RAIDZ1 HDDs — Seafile data VDisk (`vm-101` scsi1 ~3 TB), guest `/mnt/data` |
| Seafile layout | blocks + SQL dumps on `tank`; **live MariaDB on the SSD OS disk** (`/opt/seafile-mysql/db`) for commit latency |
| Other | ~120GB Crucial — planned local backup target later |

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
| [`homelab-components/`](homelab-components/) | As-built docs per component (OPNsense, oCIS, Proxmox, …) |
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
- [x] DMZ + HAProxy SNI + oCIS public (`cloud.dustinwalker.de`); Tika on, Collabora off; Tika search smoke-tested
- [x] **oCIS → Seafile 13 CE** on VM 101 (2026-08-17): Caddy replaced Traefik, production LE first try, nightly SQL dumps armed. Ingress, DNS and HAProxy untouched. Accepted loss: **no full-text content search** (CE limitation). Record: [`homelab-components/seafile/cutover-from-ocis.md`](homelab-components/seafile/cutover-from-ocis.md)

### Open to-do (post–Seafile cutover)

Detail + order: [`homelab-components/seafile/README.md`](homelab-components/seafile/README.md) §7.

- [ ] Verify Seafile upload/download round-trip + reboot test on VM 101
- [ ] Default quota 500 GB; friend accounts; self-registration off
- [ ] DMZ firewall harden (drop TEMP `DMZ → any`; block DMZ → LAN)
- [ ] Point clients at `https://cloud.dustinwalker.de` (Seafile clients; remove oCIS ones)
- [ ] Seafile SMTP via `seahub_settings.py` (Zoho) — no SMTP env vars exist
- [ ] Fresh OPNsense XML backup (private)
- [ ] Kopia offsite → friend’s TrueNAS (`/mnt/data/seafile`: blocks **and** `backup-sql/`)
- [ ] First restore drill on a disposable VM
- [ ] Local ZFS snapshots (sanoid) for the VM 101 data disk
- [x] Nightly Seafile SQL dumps (`seafile-backup-sql.timer`, 03:15, 14-day retention)
- [x] Scrutiny hub LXC 102 + host collector + **15‑min timer** (temps/history) — [`homelab-components/scrutiny/`](homelab-components/scrutiny/)
- [ ] Scrutiny email alerts (Zoho / shoutrrr)
- [ ] DynDNS for Netlify `cloud` A record
- [ ] ZFS ARC ~4 GB cap if needed under load
- [ ] Crucial SSD as local backup target
- [ ] Dockploy — see [`homelab-components/dockploy/`](homelab-components/dockploy/)
