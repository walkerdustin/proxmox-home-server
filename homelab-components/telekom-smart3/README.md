# Telekom Speedport Smart 3 (modem)

**Status:** Production — DSL modem mode  
**Last verified:** 2026-08 (modem cutover)

Rebuild context: [`../../opnsense-rebuild-guide.md`](../../opnsense-rebuild-guide.md)

---

## 1. Role

ISP modem only. OPNsense is the house router. Smart 3 does **not** provide Wi‑Fi or LAN DHCP for the house anymore.

---

## 2. Locked settings

| Item | Value |
|------|--------|
| Mode | **DSL modem mode** |
| Modem uplink to lab | **LAN 4** → Proxmox `nic1` (WAN sticker) / `vmbr1` |
| Status UI | `http://169.254.2.1` from Smart 3 **LAN 1–3** only (read-only-ish diagnostics) |
| Smart 3 Wi‑Fi | **Off** (house Wi‑Fi = UniFi on OPNsense LAN) |
| Line | Telekom VDSL (~50 Mbit/s class; later fiber possible) |

PPPoE credentials live in **OPNsense**, not on the Smart 3, once in modem mode (VLAN 7 + PPPoE on OPNsense).

---

## 3. Cabling

```text
[TAE/DSL] -- [Smart 3] --LAN4-- [nic1 / vmbr1] -- OPNsense WAN stack
```

House switch / AP / clients are **behind OPNsense LAN** (`nic2`), not on Smart 3 LAN ports used for the house.

---

## 4. Day-2 / recovery

| Action | Note |
|--------|------|
| Save Smart 3 config | Before any mode change — keep forever for rollback |
| Rollback to router mode | **Factory reset + restore** saved config (not a simple toggle) |
| Double-NAT era | Historical path used before modem cutover; see rebuild guide |

---

## 5. Related

- [`../opnsense/`](../opnsense/) — PPPoE / VLAN 7  
- [`../unifi/`](../unifi/) — house Wi‑Fi  
- [`../proxmox-host/`](../proxmox-host/) — WAN NIC  
