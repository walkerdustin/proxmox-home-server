# OPNsense on Proxmox — rebuild / cutover guide (Part 2)

**Authoritative procedure** after the 2026-08 double-NAT → modem cutover.  
Supersedes Stage 5 of [`cutover-guide.md`](cutover-guide.md). Use this if you must rebuild **without** OPNsense/Smart 3 config XML backups.

Do **not** skip verify steps. Work one checkpoint at a time.

---

## Target (final)

```text
[TAE/DSL] -- [Smart 3 MODEM · LAN4] -- [nic1 vmbr1] -- vtnet0 -- vlan01(tag7) -- pppoe0 -- OPNsense WAN
                                                                                      |
                                                         OPNsense LAN 192.168.1.1 -- vtnet1 -- vmbr0 -- nic2
                                                                                      |
                                              [PoE switch] -- UniFi AP + clients + admin PC
                                                                                      |
                                              Proxmox host IP 192.168.1.10 on vmbr0
                                                                                      |
                                              [empty] nic0 vmbr2 10.99.99.1 emergency
```

| Role | Value |
|------|--------|
| OPNsense LAN | `192.168.1.1/24`, DHCP `192.168.1.100–200` |
| Proxmox | `192.168.1.10/24`, gateway `192.168.1.1` |
| Emergency laptop | static `10.99.99.2/24`, no gateway → `https://10.99.99.1:8006` |
| Wi‑Fi | UniFi (or other AP) on the **LAN** switch — not Smart 3 |

| Sticker | NIC | Bridge |
|---------|-----|--------|
| **WAN** | `nic1` | `vmbr1` (no Proxmox IP) |
| **LAN** | `nic2` | `vmbr0` |
| **EMERGENCY** | `nic0` | `vmbr2` `10.99.99.1/24` |

---

## Why this order (lessons learned)

| Bad idea | Better idea |
|----------|-------------|
| Jump straight to modem + PPPoE + new LAN at once | Prove **double NAT** first, then change only WAN |
| Rely on locked Windows laptop static IP | Use an **admin-capable** PC + local Proxmox keyboard/monitor |
| Enable OPNsense DHCP while still on Smart 3 L2 | **Isolate** the PoE switch first |
| Create VLAN 7 and never Apply | After VLAN create, **Apply** and confirm `ifconfig vlan01` exists |
| Expect PPPoE in WAN “IPv4 type” before assignment | Create **Devices → Point-to-Point**, then assign WAN to `pppoe0` |
| Smart 3 “any LAN” for modem | Modem out is **LAN 4**; status UI `169.254.2.1` on LAN 1–3 |
| “Just switch Smart 3 back to router” | Rollback = **factory reset + restore** saved Smart 3 config |

---

## Prerequisites

- [ ] Telekom credentials written down (Anschlusskennung, Zugangsnummer, Kennwort) — never commit them
- [ ] Stickers match WAN/LAN/EMERGENCY
- [ ] UniFi (or AP) + PoE switch with enough ports for: `nic2`, AP, admin PC
- [ ] Admin-capable PC (can set static IPv4)
- [ ] Phone mobile data for chat during outages
- [ ] Local keyboard/monitor on Proxmox as break-glass
- [ ] OPNsense ISO on Proxmox; VM can use **≥ 3072 MB** RAM (2048 fails live install)
- [ ] Spare evening for modem cutover

---

## Phase 0 — Starting assumptions

This guide assumes Proxmox already has:

- `vmbr0` → `nic2`, management IP (initially often `192.168.2.10/24` gw `192.168.2.1` while Smart 3 is still a router)
- `vmbr1` → `nic1`, no IP
- `vmbr2` → `nic0`, `10.99.99.1/24`
- `vmbr3` empty (DMZ later)
- OPNsense VM 100 with `net0`→`vmbr1`, `net1`→`vmbr0`, Start at boot **Yes**

If bridges are wrong, fix them with the **dual-cable Apply** method from [`cutover-guide.md`](cutover-guide.md) Stage 3 before continuing (both `nic0` and `nic2` on house LAN while Apply moves management to `nic2`).

**Idle NIC tip:** `nic1`/`nic2` may stay DOWN with no lights until:

```bash
ip link set nic2 up
# or nic1
```

---

## Phase 1 — Backups (before any cutover)

### Proxmox

```bash
cp /etc/network/interfaces "/root/interfaces.bak-$(date +%F-%H%M)"
ip -br a
bridge link
qm config 100 | grep -E '^(net|memory|boot|onboot)'
```

Expect: `net0` bridge `vmbr1`, `net1` bridge `vmbr0`, `onboot: 1` (or Options → Start at boot Yes).

### OPNsense

System → Configuration → Backups → Download (RRD off, encryption optional).  
Store privately — **do not commit** XML to git.

### Smart 3

Einstellungen → Konfiguration sichern (before modem mode). Keep that file forever for rollback.

---

## Phase 2 — OPNsense base (if reinstalling)

1. Install UFS (not nested ZFS); set root password; remove ISO; reboot.
2. Console assign: **WAN** = `vtnet0`, **LAN** = `vtnet1` (match Proxmox net0/net1).
3. Temporary LAN for access on house `.2` network: static `192.168.2.20/24`, DHCP server **off**.
4. Or final LAN early only if you already have a recovery path to `192.168.1.1`.

GUI: hostname/timezone; leave firmware updates until OPNsense has real internet.

---

## Phase 3 — Prepare temporary WAN for double NAT

`nic1` must stay **unplugged** while you change WAN so nothing breaks yet.

1. Interfaces → Devices → Point-to-Point: create PPPoE with Telekom user/pass, parent initially `vtnet0` (you will move it to VLAN later). Keep this device even when not assigned.
2. Interfaces → Assignments: WAN device = **`vtnet0`** (hardware), not `pppoe0`.
3. Interfaces → [WAN]:
   - IPv4: **DHCP**
   - IPv6: **None**
   - **Block private networks: unchecked** (Smart 3 gives `192.168.2.x`)
   - Block bogon: checked
4. Apply. WAN has no lease until `nic1` is cabled — expected.

---

## Phase 4 — Isolate LAN and migrate to `192.168.1.0/24`

### 4a. Admin PC ready

- Ethernet to PoE switch
- Wi‑Fi off on that PC
- Temporary static e.g. `192.168.2.98/24` gw `192.168.2.1` (outside Smart 3 DHCP pool)
- Confirm reach: Proxmox `.10`, OPNsense `.20`, Smart 3 `.1`

### 4b. Keep a chat path

Enable Smart 3 Wi‑Fi temporarily **or** use phone hotspot so you are not stranded when the PoE switch leaves Smart 3.

### 4c. Cable isolation

1. Unplug **Smart 3 → PoE switch**
2. Move **Proxmox `nic2`** from Smart 3 to PoE switch (same cable, Smart 3 end → switch)

Topology:

```text
nic2 + AP + admin PC  →  PoE switch   (isolated)
Smart 3               →  DSL only
```

Verify from admin PC: `.10` and OPNsense still up; Smart 3 / internet down on that PC.

### 4d. Overlapping management IPs

Proxmox shell:

```bash
ip addr add 192.168.1.10/24 dev vmbr0
```

Admin PC (PowerShell admin), add second address:

```powershell
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 192.168.1.98 -PrefixLength 24
ping 192.168.1.10
```

### 4e. OPNsense LAN + DHCP

Console option **2** (or GUI if both subnets reachable):

- LAN `192.168.1.1/24`
- DHCP server **on**: `192.168.1.100`–`192.168.1.200`
- No LAN upstream gateway

Verify runtime:

```sh
ifconfig vtnet1 | grep inet
```

Must show `192.168.1.1` (reboot OPNsense once if config says `.1.1` but ifconfig still shows old `.2.x`).

### 4f. Persist Proxmox management

1. Open `https://192.168.1.10:8006`
2. System → Network → `vmbr0`: `192.168.1.10/24`, gateway `192.168.1.1`, ports `nic2`
3. Apply
4. Confirm routes: default via `192.168.1.1`

### 4g. Prove DHCP

Admin PC → Automatic DHCP → expect `192.168.1.100–200`, gw/DNS `192.168.1.1`.

---

## Phase 5 — Double NAT (prove the router)

1. Cable: **Smart 3 LAN 4 → `nic1` (WAN)**  
   (Use LAN 4 already — same port as modem mode later.)
2. OPNsense WAN should get `192.168.2.x` from Smart 3.
3. Verify from a LAN client:
   - Internet works
   - `tracert` / `traceroute`: hop1 = `192.168.1.1`, hop2 = `192.168.2.1`, then Telekom
   - Proxmox + OPNsense UIs
4. Move Wi‑Fi: power-cycle UniFi AP; clients get `.1.x`; disable Smart 3 Wi‑Fi.
5. Firmware update OPNsense **now** (internet exists).
6. Download a fresh OPNsense backup; copy Proxmox `interfaces` again.
7. Reboot tests (one at a time): OPNsense → Proxmox (confirm Start at boot) → optional Smart 3.

**Soak** hours or overnight before modem mode.

---

## Phase 6 — Stage VLAN 7 + PPPoE (internet must stay on DHCP WAN)

1. Interfaces → Devices → VLAN: parent `vtnet0`, tag **7**, device e.g. `vlan01` → **Save → Apply**.
2. Shell: `ifconfig vlan01` must exist (`vlan: 7`, parent `vtnet0`). If missing, Apply again or recreate.
3. Point-to-Point `pppoe0`: **Link interface = `vlan01` only** (not `vtnet0`).
4. Assignments: WAN remains **`vtnet0` DHCP**. Internet still via double NAT.
5. Verify internet still works.

---

## Phase 7 — Modem cutover

Expect full internet outage until PPPoE comes up. Local `.1.1` / `.1.10` should stay reachable.

1. Fresh Smart 3 **Konfiguration sichern**.
2. Einstellungen → DSL-Modem → **Speedport als DSL-Modem nutzen** → wait reboot.
3. Confirm: `.1.1` and `.1.10` up; internet down; `.2.1` gone.
4. OPNsense Assignments: WAN → **`pppoe0`**.
5. Interfaces → [WAN]:
   - Device `pppoe0`
   - IPv4 PPPoE
   - IPv6 None
   - **Block private networks: checked**
   - Block bogon: checked
6. Save / Apply.
7. If Overview shows no WAN IP and shell says `vlan01`/`pppoe0` does not exist → open VLAN page → **Apply**, then recheck.
8. Success when:
   - WAN has a **public** IPv4
   - Gateway exists
   - `tracert` hop1 = `192.168.1.1`, hop2 = Telekom (**not** `192.168.2.1`)
9. Reboot OPNsense once; confirm PPPoE returns.
10. Download final OPNsense backup; update [`memory.md`](memory.md).

---

## Rollback (modem failed, double NAT was good)

1. Factory-reset Smart 3; restore saved router config.
2. Cable: Smart 3 normal LAN → `nic1` (LAN 4 still fine).
3. OPNsense WAN → `vtnet0` DHCP; block private networks **off**.
4. Leave LAN at `192.168.1.0/24` — no need to undo house addressing.
5. Debug PPPoE / VLAN later.

---

## Emergency access

| Problem | Action |
|---------|--------|
| House LAN dead | Laptop → Realtek `nic0`, static `10.99.99.2/24`, `https://10.99.99.1:8006` (needs admin rights for static IP) |
| No admin static IP | Keyboard/monitor on Proxmox; fix `/etc/network/interfaces` or start OPNsense console |
| OPNsense LAN IP wrong | VM console option 2 |
| VLAN missing after reboot | Devices → VLAN → Apply; `ifconfig vlan01` |

---

## Quick reference — OPNsense devices

| Logical | Device |
|---------|--------|
| WAN parent | `vtnet0` |
| Telekom VLAN | `vlan01` tag 7 |
| WAN assigned | `pppoe0` |
| LAN | `vtnet1` = `192.168.1.1/24` |

---

## Phase 2 (not this guide)

DMZ `vmbr3`, Dockploy, Seafile, DynDNS, HAProxy/SNI — after this topology is stable.
