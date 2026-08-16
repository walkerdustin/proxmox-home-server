# Dockploy (planned)

**Status:** Not installed  
**Last updated:** 2026-08-16  

Architecture intent: [`../../homeserver-plan.md`](../../homeserver-plan.md) §4–5 · Ingress pattern: [`../../ocis-public-ingress-plan.md`](../../ocis-public-ingress-plan.md)

---

## 1. Role (planned)

DMZ Docker host for public web apps (Traefik, later Supabase/pgvector, etc.). Separate from oCIS so app deploys do not share the file-cloud VM.

---

## 2. Planned placement

| Item | Planned value |
|------|----------------|
| Network | DMZ `vmbr3` (new static IP, e.g. `10.10.10.x` — pick when installing) |
| Resources (plan) | ~4 vCPU, ~14 GB RAM on 32 GB host |
| TLS | Traefik on the Dockploy VM |
| Ingress | Same OPNsense HAProxy pattern: SNI/Host → this VM `:443`/`:80` |

Do **not** mix TLS terminate on OPNsense with passthrough on the same VIP.

---

## 3. Open to-do

- [ ] Create VM + OS on DMZ (`vmbr3`)  
- [ ] Install Dockploy / Traefik stack  
- [ ] OPNsense HAProxy real servers + SNI/Host rules (same pattern as oCIS; separate from `cloud.*`)  
- [ ] DNS names for apps (Netlify)  
- [ ] Firewall hardening for the new DMZ host  

When live, replace this stub with as-built IPs, compose paths, and hostnames (same template as [`../ocis/`](../ocis/)). Put compose/env examples in this folder.

---

## 4. Related

- [`../opnsense/`](../opnsense/) — HAProxy extension point  
- [`../ocis/`](../ocis/) — working reference implementation of DMZ + passthrough  
- [`../proxmox-host/`](../proxmox-host/)  
