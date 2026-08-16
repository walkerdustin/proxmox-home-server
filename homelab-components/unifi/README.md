# UniFi U7 (Wi‑Fi)

**Status:** Production  
**Last verified:** 2026-08 (post modem cutover)

---

## 1. Role

House Wi‑Fi access point on the **OPNsense LAN**, powered by the PoE switch. Replaces Smart 3 Wi‑Fi after modem mode.

---

## 2. Placement & network

| Item | Value |
|------|--------|
| AP | UniFi **U7** |
| Uplink | PoE switch on house LAN (`192.168.1.0/24`) |
| Gateway / DHCP / DNS | OPNsense `192.168.1.1` |
| Smart 3 Wi‑Fi | Off |

Clients get DHCP from OPNsense (`192.168.1.100`–`200`) and use Unbound (including split DNS for `cloud.dustinwalker.de` → `10.10.10.10`).

---

## 3. Locked intent

- AP is an **access layer** device only — not the edge router  
- No second DHCP server on the same L2 as OPNsense  
- Isolate PoE switch during LAN migrations so two DHCP servers never collide (see rebuild guide)

---

## 4. Day-2

- Adopt/manage via UniFi Network application (exact controller host not pinned in repo yet — update when documented)  
- After OPNsense/Unbound changes, renew DHCP or flush DNS on clients if names look wrong  

---

## 5. Related

- [`../opnsense/`](../opnsense/)  
- [`../telekom-smart3/`](../telekom-smart3/)  
- [`../proxmox-host/`](../proxmox-host/)  
