# Seafile 13 Community Edition

**Status:** Live (public HTTPS)
**Last verified:** 2026-08-17
**Public URL:** https://cloud.dustinwalker.de

Cutover runbook: [`cutover-from-ocis.md`](cutover-from-ocis.md) · Backup design: [`backup-to-truenas.md`](backup-to-truenas.md) · Disaster path: [`disaster-restore.md`](disaster-restore.md)
Predecessor (decommissioned): [`../ocis/`](../ocis/) · Ingress model: [`../../ocis-public-ingress-plan.md`](../../ocis-public-ingress-plan.md) · Architecture: [`../../storage_server_setup.md`](../../storage_server_setup.md)

---

## 1. Role

Private cloud for files (sync, share) for the admin and friends, 500 GB quota each. Internet-facing via OPNsense HAProxy → **Caddy** on this VM, where TLS terminates (Let's Encrypt).

Replaced oCIS on 2026-08-17. The driver was admin visibility: Seafile ships a per-user usage / quota / last-login table and stats, which oCIS never exposed outside the API. See §8 for what that cost.

---

## 2. Where it runs

| Item | Value |
|------|--------|
| Proxmox VM | **101** `seafile` (renamed from `ocis` 2026-08-18; disk label stays `ocis-data` — historical, mounted by label in `/etc/fstab`) |
| OS | Debian (headless) |
| vCPU / RAM | 2 / 6 GB |
| OS disk | `scsi0` on `local-zfs` (~32G) — also holds the live MariaDB |
| Data disk | `scsi1` on `tank` (~3 TB), mounted in guest at **`/mnt/data`** |
| Bridge | `vmbr3` (DMZ) |
| Guest IP | `10.10.10.10/24` |
| Gateway | `10.10.10.1` (OPNsense DMZ) |
| DNS (guest) | `10.10.10.1`, `1.1.1.1` via `resolvconf` + `dns-nameservers` in `/etc/network/interfaces` |

The ZFS pool and the scsi1 vdisk were **reused as-is** during the cutover — no pool rebuild, no fstab change.

---

## 3. Addresses & DNS

| Path | Address |
|------|---------|
| Public | `cloud.dustinwalker.de` → WAN IPv4 (Netlify **A** record; **manual** DynDNS for now) |
| LAN (split DNS) | Unbound host override → `10.10.10.10` |
| Registrar | Porkbun (NS at **Netlify**) |

Ingress — **unchanged** from the oCIS build; only the container terminating TLS differs:

```text
Internet :443 ── HAProxy TCP SNI ──► 10.10.10.10:443  (Caddy)
Internet :80  ── HAProxy HTTP Host ► 10.10.10.10:80   (Caddy ACME + redirect)
```

Verified on 2026-08-17: the HTTP-01 challenge was served to `10.10.10.1` (OPNsense/HAProxy), so the passthrough carries ACME end to end.

---

## 4. Locked application settings

**Stack:** official Seafile **CE 13.0** Docker Compose (CE 13 dropped binary installs; Compose is the only supported path). Requires Compose ≥ 2.30.0 — host has v5.4.0.

| Item | Value |
|------|--------|
| Compose dir | `/opt/compose/seafile` |
| Compose files | `.env`, `seafile-server.yml`, `caddy.yml` (upstream, unmodified) |
| `COMPOSE_FILE` | `'seafile-server.yml,caddy.yml'` |
| Example env (sanitized) | [`seafile.env.example`](seafile.env.example) |
| Seafile image | `seafileltd/seafile-mc:13.0-latest` |
| Database | `mariadb:10.11` |
| Cache | `redis` (13.0 replaced memcached), `requirepass` set |
| TLS proxy | `lucaslorentz/caddy-docker-proxy:2.12-alpine` |
| `SEAFILE_SERVER_HOSTNAME` | `cloud.dustinwalker.de` |
| `SEAFILE_SERVER_PROTOCOL` | **`https`** |
| `TIME_ZONE` | `Europe/Berlin` |
| Block store | `/mnt/data/seafile/data` (`tank`) |
| MariaDB (live) | `/opt/seafile-mysql/db` (**SSD**) |
| Caddy certs | `/mnt/data/seafile/caddy` |
| SQL dumps | `/mnt/data/seafile/backup-sql/YYYY-MM-DD-HHMM/` (`tank`) |
| ACME | Production Let's Encrypt, obtained first try 2026-08-17; renewal window ~mid-Oct 2026 |
| SeaDoc | **off** (`ENABLE_SEADOC=false`; `seadoc.yml` not downloaded) |
| Notification server | **off** |
| Seafile AI / face recognition | **off** |
| SMTP | **live 2026-08-18** — Zoho EU `smtp.zoho.eu`:465 SSL; auth `zfs.notification@dustinwalker.de`; from `Dustins Seafile Cloud <cloud@dustinwalker.de>` (alias). Password in `seahub_settings.py` only |
| Admin user | `mail@dustinwalker.de` (password only in server `.env`, not in git) |

Two settings that are load-bearing and easy to get wrong:

- **`SEAFILE_SERVER_PROTOCOL=https`** does double duty: `caddy.yml` builds the vhost as `${SEAFILE_SERVER_PROTOCOL}://${SEAFILE_SERVER_HOSTNAME}`, so `http` here means no certificate *and* Seahub hands out `http` fileserver links — which presents as working logins with broken uploads.
- **`COMPOSE_FILE` must not list `seadoc.yml`** while that file is absent; Compose hard-fails on a missing file.

`BASIC_STORAGE_PATH` is left at the upstream `/opt` and is inert — all three active volume paths are set explicitly, and the only line still referencing it (`SEADOC_VOLUME`) is unused.

Related OPNsense pieces (see [`../opnsense/`](../opnsense/)) — untouched by the cutover:

- Plugin `os-haproxy`: frontends `wan-https` (`0.0.0.0:443` TCP SNI) and `wan-http` (`0.0.0.0:80`)
- WAN pass TCP 80/443 to **WAN address**
- Web GUI on **LAN only**, port **8443**, GUI HTTP→HTTPS redirect **disabled**

---

## 5. Dependencies

- OPNsense DMZ interface + LAN↔DMZ rules; WAN 80/443 → HAProxy
- Netlify A record for `cloud` matching current WAN IP
- Guest static IP + working DNS (`resolvconf`) — an empty `/etc/resolv.conf` breaks LE renewals
- Data disk mounted at `/mnt/data` **before** Compose start
- Docker Compose ≥ 2.30.0

---

## 6. Day-2 operations

### Start / stop

`.env` is root-owned mode `600`, so **every Compose command needs `sudo`**. Without it you get a misleading "variable is not set" abort from the `:?` guard on the hostname rather than a permission error.

```bash
cd /opt/compose/seafile
sudo docker compose ps
sudo docker logs seafile -f
sudo docker logs seafile-caddy -f
sudo docker compose up -d
```

Expected containers: `seafile`, `seafile-mysql`, `seafile-redis`, `seafile-caddy`.

### Upgrade

1. Snapshot VM 101 and run [`backup-sql.sh`](#backups) first.
2. Read the Seafile release notes — **also** re-download `.env`/`*.yml` when the recipe changes between majors (12→13 replaced memcached with Redis and added new services).
3. `sudo docker compose pull && sudo docker compose up -d`
4. Watch `sudo docker logs seafile -f` through the schema migration.

Consider pinning an exact patch tag instead of the moving `13.0-latest`.

### Admin password reset

```bash
sudo docker exec -it seafile /opt/seafile/seafile-server-latest/reset-admin.sh
```

`INIT_SEAFILE_ADMIN_*` only apply on **first** startup; editing them later does nothing.

### SMTP

Seafile has **no SMTP env vars** — configure `/mnt/data/seafile/data/seafile/conf/seahub_settings.py`, then `sudo docker restart seafile`.

### Quotas

Admin panel → **System Admin** → Settings for the default quota; per-user override in the **Users** table (used/quota/last login).

### Garbage collection

```bash
sudo docker exec -it seafile /opt/seafile/seafile-server-latest/seaf-gc.sh --dry-run
```

**Never run GC during the backup window** — blocks deleted mid-copy is the corruption case in [`backup-to-truenas.md`](backup-to-truenas.md) §7.

### Backups

DB-first, per [`backup-to-truenas.md`](backup-to-truenas.md) §2.

| Item | Value |
|------|--------|
| Script | `/opt/compose/seafile/backup-sql.sh` (mode `700`) |
| Timer | `seafile-backup-sql.timer` — daily **03:15**, `Persistent=true` |
| Output | `/mnt/data/seafile/backup-sql/<stamp>/{ccnet,seafile,seahub}_db.sql` |
| Retention (local) | 14 days |
| Tooling | `mariadb-dump --opt --single-transaction` (not the deprecated `mysqldump` wrapper) |
| Failure mail | Host cron at **12:00** — [`../proxmox-host/configs/seafile-sql-dump-alert.sh`](../proxmox-host/configs/seafile-sql-dump-alert.sh). The guest timer itself is silent on failure |

Dumps land on `tank` beside the block store deliberately: one Kopia job and one ZFS snapshot then capture a **consistent restore set**.

```bash
sudo systemctl list-timers seafile-backup-sql.timer
sudo journalctl -u seafile-backup-sql.service -n 50
# on pve:
/usr/local/sbin/seafile-sql-dump-alert.sh --test
```

### Common failures

| Symptom | Likely cause |
|---------|----------------|
| Login works, uploads fail | `SEAFILE_SERVER_PROTOCOL` not `https` |
| Compose aborts: "variable is not set or empty" | Ran without `sudo`; `.env` unreadable |
| Compose aborts on missing file | `seadoc.yml` still listed in `COMPOSE_FILE` |
| `seafile-redis` restart loop | `REDIS_PASSWORD` set for one service but not the other (both lines 37 + 73 of `seafile-server.yml` read it) |
| Public timeout, HAProxy OPEN | Stale Netlify A record (WAN IP changed) |
| `Could not resolve host` on VM | `/etc/resolv.conf` empty — fix `resolvconf` |
| `169.254` / no reachability | DHCP/link-local on the NIC — keep **static** only |
| Sluggish web UI | Check MariaDB really is on `/opt/...` (SSD), not `tank` |

---

## 7. Open to-do

Carried over from the oCIS build; host-wide items also tracked in [`../../memory.md`](../../memory.md).

### Soon (safety / correctness)

- [ ] **Verify upload + download round-trip** and re-test on mobile data *and* Wi-Fi (split DNS)
- [ ] **Reboot test** VM 101 — `ip route` shows `default via 10.10.10.1`, no `169.254`, all four containers return, cert persists
- [x] **Users locked 2026-09-17** — self-registration off; accounts exist; 500 GB per user in the Users table (Phillip 1 TB). Global `[quota] default` left unset on purpose: new users are created by hand
- [x] **DMZ firewall hardened 2026-08-18** — 8 ordered rules; `DMZ → LAN` and `DMZ → This Firewall` blocked + logged; TEMP allow-any disabled (not deleted). See [`../opnsense/README.md`](../opnsense/README.md) §6
- [ ] **Clients** — Seafile desktop/mobile against `https://cloud.dustinwalker.de`; remove oCIS clients and their old sync folders
- [x] **SMTP live 2026-08-18** — verified end-to-end via the Forgot-Password flow
- [ ] Switch to a **dedicated Zoho app-specific password** (currently the shared mailbox password)
- [x] SPF + DKIM verified 2026-08-18 — `include:zoho.eu`; DKIM selector **`zmail`** (not `zoho`)
- [ ] **DMARC** absent — optional, `v=DMARC1; p=none;` to start
- [ ] **Send-quota isolation** — Seafile shares the ZFS-alert mailbox quota via the `cloud@` alias; a share-mail burst must not starve HDD failure alerts. Own mailbox and/or longer `[SEAHUB EMAIL] interval`
- [x] **DMZ egress TCP 465** on the allow-list (rule 7) — verified with a TLS handshake to `smtp.zoho.eu:465` from the guest after hardening
- [ ] **Fresh OPNsense XML backup** (keep private; do not commit)

### Backups & host health

- [x] Nightly SQL dumps + systemd timer
- [ ] **Kopia → friend's TrueNAS** — encrypted offsite of `/mnt/data/seafile` (block store **and** `backup-sql/`); SFTP vs MinIO still open
- [ ] **First restore drill** on a disposable VM ([`disaster-restore.md`](disaster-restore.md))
- [ ] **Local ZFS snapshots** (sanoid) for the VM 101 data disk
- [ ] **DynDNS** — automate the Netlify `cloud` A record
- [x] Drive temps / history — Scrutiny LXC 102 ([`../scrutiny/`](../scrutiny/)) is dashboard-only; **temperature alerting** lives on the host ([`../proxmox-host/configs/drive-temp-alert.sh`](../proxmox-host/configs/drive-temp-alert.sh), 2026-08-22)

### Later / optional

- [ ] Pin an exact Seafile patch tag
- [x] Renamed VM + guest hostname `ocis` → `seafile` (2026-08-18)
- [ ] Cap ZFS ARC ~4 GB once the HDD pool is under load
- [ ] Local backup target on the Crucial SSD (Proxmox backup of the OS disk)
- [ ] Reconsider SeaDoc if in-browser markdown editing is ever wanted

---

## 8. Accepted regression: no full-text search

Seafile **CE** searches file and folder **names** only. Content search inside PDF/Office files is Professional-only. The oCIS + Tika content search (smoke-tested 2026-08-16) was given up deliberately in exchange for the admin usage/quota UI.

Pro is historically free for ≤ 3 users, which does not fit the friends-with-quotas plan. If content search later outweighs the admin UI, that tradeoff — not the deployment — is what has to be revisited.

---

## 9. Explicit non-goals (current)

- Full-text content search (see §8)
- SeaDoc, OnlyOffice, Collabora
- Seafile AI / face recognition
- Notification server
- IPv6
- DynDNS automation **until** the to-do above (manual Netlify A updates for now)
- Server-side E2EE beyond Seafile's own encrypted libraries; zero-knowledge users bring Cryptomator
