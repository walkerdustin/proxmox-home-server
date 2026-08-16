# ownCloud Infinite Scale (oCIS)

**Status:** Live (public HTTPS)  
**Last verified:** 2026-08-16  
**Public URL:** https://cloud.dustinwalker.de  

Planning / edge cases: [`../../ocis-public-ingress-plan.md`](../../ocis-public-ingress-plan.md) · Architecture notes: [`../../storage_server_setup.md`](../../storage_server_setup.md)

---

## 1. Role

Private cloud for files (sync, share, search). Internet-facing via OPNsense HAProxy → Traefik on this VM. TLS terminates on Traefik (Let’s Encrypt).

---

## 2. Where it runs

| Item | Value |
|------|--------|
| Proxmox VM | **101** `ocis` |
| OS | Debian (headless) |
| vCPU / RAM | 2 / 6 GB |
| OS disk | `scsi0` on `local-zfs` (~32G) |
| Data disk | `scsi1` on `tank` (~3 TB), mounted in guest at **`/mnt/data`** |
| Bridge | `vmbr3` (DMZ) |
| Guest IP | `10.10.10.10/24` |
| Gateway | `10.10.10.1` (OPNsense DMZ) |
| DNS (guest) | `10.10.10.1`, `1.1.1.1` via `resolvconf` + `dns-nameservers` in `/etc/network/interfaces` |

---

## 3. Addresses & DNS

| Path | Address |
|------|---------|
| Public | `cloud.dustinwalker.de` → WAN IPv4 (Netlify **A** record; **manual** DynDNS for now) |
| LAN (split DNS) | Unbound host override → `10.10.10.10` |
| Registrar | Porkbun (NS at **Netlify**) |

Ingress:

```text
Internet :443 ── HAProxy TCP SNI ──► 10.10.10.10:443  (Traefik)
Internet :80  ── HAProxy HTTP Host ► 10.10.10.10:80   (Traefik ACME + redirect)
```

---

## 4. Locked application settings

**Stack:** official `ocis_full` from GitHub branch **`stable-8.0`**

| Item | Value |
|------|--------|
| Compose dir | `/opt/compose/ocis/ocis_full` |
| Example env (sanitized) | [`ocis.env.example`](ocis.env.example) |
| Image | `owncloud/ocis:8.0.1` |
| Traefik | `traefik:v3.6.7` (from example) |
| Domain | `OCIS_DOMAIN=cloud.dustinwalker.de` |
| ACME mail | `letsencrypt@dustinwalker.de` |
| ACME | Production Let’s Encrypt (staging used once, then cert volume wiped) |
| `INSECURE` | commented / off |
| Collabora | **off** (`# COLLABORA=:collabora.yml`) |
| Tika (search) | **on** (`TIKA=:tika.yml`) |
| Demo users | `false` |
| Config / data | `/mnt/data/ocis/config`, `/mnt/data/ocis/data` |
| SMTP | not configured yet |
| Admin user | `admin` (password only on server `.env`, not in git) |

Related OPNsense pieces (see [`../opnsense/`](../opnsense/)):

- Plugin `os-haproxy`: frontends `wan-https` (`0.0.0.0:443` TCP SNI) and `wan-http` (`0.0.0.0:80`)
- WAN pass TCP 80/443 to **WAN address**
- Web GUI moved to **LAN only**, port **8443**, GUI HTTP→HTTPS redirect **disabled** (so HAProxy can own 80/443)

---

## 5. Dependencies

- OPNsense DMZ interface + LAN↔DMZ rules; WAN 80/443 → HAProxy  
- Netlify A record for `cloud` matching current WAN IP  
- Guest static IP + working DNS (`resolvconf`) — empty `/etc/resolv.conf` breaks `git` / LE renewals  
- Data disk mounted at `/mnt/data` before Compose start  

---

## 6. Day-2 operations

### Start / stop

```bash
cd /opt/compose/ocis/ocis_full
docker compose ps
docker compose logs -f traefik
docker compose pull   # only when intentionally upgrading pins
docker compose up -d
```

### Upgrade oCIS

1. Snapshot VM 101 (or ZFS snap of data disk).  
2. Bump `OCIS_DOCKER_TAG` in `.env` (keep `owncloud/ocis`, not rolling, unless you choose rolling deliberately).  
3. `docker compose pull && docker compose up -d`  
4. Read release notes; refresh compose files from a newer `stable-*` only when the recipe changes.

### Certificates

- Leave WAN **:80** open permanently (HTTP-01 renewals).  
- Staging→prod: empty `TRAEFIK_ACME_CASERVER`, `docker compose down`, `docker volume rm ocis_full_certs`, `up -d`.

### Admin password reset

```bash
cd /opt/compose/ocis/ocis_full
docker compose exec ocis ocis idm resetpassword
```

### Common failures

| Symptom | Likely cause |
|---------|----------------|
| Public timeout, HAProxy OPEN | Stale Netlify A record (WAN IP changed) |
| `Could not resolve host` on VM | `/etc/resolv.conf` empty — install/fix `resolvconf` |
| Login loop / „Nicht angemeldet“ with staging cert | Untrusted cert breaks OIDC cookies — use production LE |
| `169.254` / no LAN reachability | DHCP/link-local on ens18 — keep **static** only |

### Backups

- VM snapshot before stack changes (e.g. `before-ocis-public-ingress`)  
- Data on `tank` via scsi1 → `/mnt/data`  
- Kopia offsite to friend’s TrueNAS: **open** (see below; design in [`../../storage_server_setup.md`](../../storage_server_setup.md))

---

## 7. Open to-do

Rough order for what’s left after public HTTPS. Check items off here (and in [`../../memory.md`](../../memory.md) for host-wide items).

### Soon (safety / correctness)

- [ ] **DMZ firewall harden (Phase E)** — on OPNsense: remove TEMP `DMZ → any`; allow only what oCIS needs outbound (DNS, HTTP/HTTPS, NTP); **block DMZ → LAN** (see [`../opnsense/`](../opnsense/), [`../../ocis-public-ingress-plan.md`](../../ocis-public-ingress-plan.md))
- [ ] **Clients** — point desktop/mobile oCIS apps at `https://cloud.dustinwalker.de` (not old LAN/`9200` URLs)
- [ ] **SMTP for oCIS** — wire Zoho (or dedicated mailbox) into `.env` (`SMTP_*`) so share/password notifications work
- [ ] **Fresh OPNsense XML backup** — after HAProxy / GUI-port / DMZ changes (keep private; do not commit)

### Backups & host health (not only oCIS)

- [ ] **Kopia → friend’s TrueNAS** — encrypted offsite of `/mnt/data/ocis` (RO mount into Kopia; SFTP or S3/MinIO)
- [ ] **Local ZFS snapshots** — e.g. sanoid on Proxmox for VM 101 data disk (`tank`), short retention
- [x] **Drive temps / history** — Scrutiny LXC 102 ([`../scrutiny/`](../scrutiny/)); email alerts still open there
- [ ] **DynDNS** — automate Netlify `cloud` A record (WAN IP already changed once); until then keep TTL low and update manually

### Later / optional

- [ ] User space quotas (~500 GB) if not already set
- [ ] Cap ZFS ARC ~4 GB on Proxmox once HDD pool is under load
- [ ] Local backup target on Crucial SSD (PBS / Proxmox backup of OS disk)
- [ ] ClamAV / web extensions only if you actually want them

Dockploy is tracked in [`../dockploy/`](../dockploy/), not here.

### Done (keep for context)

- [x] Tika enabled; content search smoke-tested (PDF on Wi‑Fi)
- [x] Public ingress live (`cloud.dustinwalker.de`, production LE)

---

## 8. Explicit non-goals (current)

- Collabora / OnlyOffice  
- DynDNS automation **until** the DynDNS to-do above (manual Netlify A updates for now)  
- ClamAV, Draw.io / JSON viewer web extensions  
- Exposing Traefik dashboard publicly  
