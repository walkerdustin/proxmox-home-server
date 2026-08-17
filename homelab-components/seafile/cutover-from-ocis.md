# Seafile cutover (replace oCIS on VM 101)

**Status:** Ready to execute
**Last updated:** 2026-08-17
**Target:** Seafile **13.0 Community Edition**, Docker Compose, on existing VM 101
**Public URL:** `https://cloud.dustinwalker.de` (unchanged)

Parent: [`README.md`](README.md) · Backup design: [`backup-to-truenas.md`](backup-to-truenas.md) · Disaster path: [`disaster-restore.md`](disaster-restore.md)
Ingress this reuses verbatim: [`../../ocis-public-ingress-plan.md`](../../ocis-public-ingress-plan.md) §3.5 · Outgoing stack: [`../ocis/README.md`](../ocis/README.md)

---

## 1. Locked decisions

| Decision | Choice | Why |
|----------|--------|-----|
| VM | **Reuse VM 101 in place** (keep Debian) | Preserves static DMZ IP, `resolvconf` fix, guest agent — the fragile parts (`169.254` footgun) |
| Edition | **Community Edition 13.0** | Free for >3 users; admin usage/quota UI is the whole point of switching |
| Deployment | Official Docker Compose (CE) | CE 13 dropped binary installs; Compose is the only supported path |
| Public hostname | `cloud.dustinwalker.de` **unchanged** | Netlify A record, HAProxy SNI ACL, Unbound override all already correct |
| TLS | **Caddy** in the Seafile stack (`:80` + `:443`) | Same pattern Traefik used; HAProxy SNI passthrough needs **zero** changes |
| Block store | `/mnt/data/seafile/data` on `tank` | Same 3 TB vdisk, same mount — no Proxmox disk work |
| MariaDB | `/opt/seafile-mysql/db` on **SSD** (`local-zfs`) + nightly dumps to `tank` | RAIDZ1 HDD without SLOG makes every SQL commit slow; dumps keep one consistent Kopia/ZFS restore set |
| Cache | **Redis** (13.0 default; replaced memcached) | Upstream default |
| SeaDoc | **Off** | Matches the no-office stance; ~400 MB RAM saved on 6 GB |
| Notification server / Seafile AI / face recognition | **Off** | Not wanted; AI keys are out of scope |
| ZFS pool | **Not touched** | `tank` and the `vm-101` scsi1 vdisk are reused as-is |

### Accepted regression

**No full-text content search.** Seafile CE searches file/folder **names** only; content search inside PDF/Office is Pro-only. The oCIS + Tika content search is being given up deliberately.

---

## 2. Data flow after cutover

```text
Internet
  :443 ── HAProxy (TCP, SNI cloud.dustinwalker.de) ──► 10.10.10.10:443  (Caddy)
  :80  ── HAProxy (HTTP, Host) ─────────────────────► 10.10.10.10:80   (Caddy ACME + redirect)

VM 101 (10.10.10.10, DMZ)
  seafile-caddy  :80/:443  ── docker net seafile-net ──► seafile :80
  seafile        blocks ──► /mnt/data/seafile/data      (tank, RAIDZ1)
  seafile-mysql  DB     ──► /opt/seafile-mysql/db       (SSD, local-zfs)
  seafile-redis  cache  ──► ephemeral
  nightly dump          ──► /mnt/data/seafile/backup-sql/YYYY-MM-DD-HHMM/
```

---

## 3. Phase 0 — Safety net

On Proxmox host:

```bash
qm snapshot 101 before-seafile-cutover --description "last oCIS state"
qm listsnapshot 101
```

Also record, on the OPNsense Overview page, the current WAN IPv4 and confirm the Netlify `cloud` A record still matches (nothing else in this cutover fixes a stale record).

**Gate:** snapshot exists; `nslookup cloud.dustinwalker.de` from outside returns the current WAN IP.

---

## 4. Phase 1 — Tear down oCIS

On VM 101. Confirm nothing else runs here first (Scrutiny is LXC 102, Dockploy is not deployed):

```bash
docker ps -a
```

Then remove the stack, its volumes, and its data:

```bash
cd /opt/compose/ocis/ocis_full
docker compose down -v            # -v also drops the certs + ocis-apps volumes

docker ps -a                      # expect empty
docker system prune -a --volumes  # reclaim images/volumes; safe: oCIS was the only stack

rm -rf /mnt/data/ocis
rm -rf /opt/compose/ocis
df -h /mnt/data
```

**Gate:** `docker ps -a` empty, `/mnt/data/ocis` gone, `:80`/`:443` free (`ss -ltnp | grep -E ':80|:443'` silent).

---

## 5. Phase 2 — Host prerequisites

Compose **2.30.0+** is required by Seafile 12/13:

```bash
docker --version
docker compose version
```

If Compose is older than 2.30.0, update `docker-compose-plugin` from Docker's official repo before continuing.

Create the directory layout:

```bash
mkdir -p /opt/compose/seafile
mkdir -p /opt/seafile-mysql/db
mkdir -p /mnt/data/seafile/data
mkdir -p /mnt/data/seafile/caddy
mkdir -p /mnt/data/seafile/backup-sql
```

---

## 6. Phase 3 — Fetch official CE files

```bash
cd /opt/compose/seafile
wget -O .env https://manual.seafile.com/13.0/repo/docker/ce/env
wget https://manual.seafile.com/13.0/repo/docker/ce/seafile-server.yml
wget https://manual.seafile.com/13.0/repo/docker/caddy.yml
```

`seadoc.yml` is deliberately **not** downloaded — which means `COMPOSE_FILE` in `.env` must have `seadoc.yml` removed or Compose fails on a missing file.

Before editing, check two things in the downloaded `seafile-server.yml`:

```bash
grep -n -A4 'redis:' seafile-server.yml     # does the redis command require REDIS_PASSWORD?
grep -n 'caddy' seafile-server.yml          # which caddy.* labels drive the vhost
```

If the redis `command` interpolates `${REDIS_PASSWORD}` unconditionally, set a value; if it is a literal or defaulted, leave `REDIS_PASSWORD` empty as shipped (Redis is only reachable on the internal `seafile-net`).

---

## 7. Phase 4 — Configure `.env`

Generate secrets (hex only — avoids `.env` quoting and MariaDB escaping problems):

```bash
openssl rand -hex 32   # JWT_PRIVATE_KEY (needs >= 32 chars)
openssl rand -hex 24   # SEAFILE_MYSQL_DB_PASSWORD
openssl rand -hex 24   # INIT_SEAFILE_MYSQL_ROOT_PASSWORD
```

Edit the values in place (do **not** append duplicates). Sanitized reference: [`seafile.env.example`](seafile.env.example).

| Key | Value |
|-----|-------|
| `COMPOSE_FILE` | `'seafile-server.yml,caddy.yml'` |
| `SEAFILE_VOLUME` | `/mnt/data/seafile/data` |
| `SEAFILE_MYSQL_VOLUME` | `/opt/seafile-mysql/db` |
| `SEAFILE_CADDY_VOLUME` | `/mnt/data/seafile/caddy` |
| `SEAFILE_SERVER_HOSTNAME` | `cloud.dustinwalker.de` |
| `SEAFILE_SERVER_PROTOCOL` | `https` |
| `TIME_ZONE` | `Europe/Berlin` |
| `JWT_PRIVATE_KEY` | generated |
| `SEAFILE_MYSQL_DB_PASSWORD` | generated |
| `INIT_SEAFILE_MYSQL_ROOT_PASSWORD` | generated |
| `INIT_SEAFILE_ADMIN_EMAIL` | your admin mailbox |
| `INIT_SEAFILE_ADMIN_PASSWORD` | strong, from password manager |
| `CACHE_PROVIDER` | `redis` |
| `ENABLE_SEADOC` | `false` |
| `ENABLE_NOTIFICATION_SERVER` | `false` |
| `ENABLE_SEAFILE_AI` / `ENABLE_FACE_RECOGNITION` | `false` |

`SEAFILE_SERVER_PROTOCOL=https` is what makes Caddy request a certificate **and** what makes Seahub hand out correct upload links — an `http` value here produces working logins with broken uploads.

`BASIC_STORAGE_PATH` becomes irrelevant once the three volume paths are set explicitly; leave it or set it to `/mnt/data/seafile`, but the explicit lines are what matter.

Lock the file down:

```bash
chmod 600 .env
```

Optionally pin the image to an exact patch instead of the moving `13.0-latest` (matches the oCIS pinning habit).

**Never commit `.env`.**

---

## 8. Phase 5 — Pre-flight before the first start

Certificates are issued on first boot, so verify the path **before** starting:

```bash
nslookup cloud.dustinwalker.de 1.1.1.1     # must equal current WAN IP
ss -ltnp | grep -E ':80|:443'              # must be silent
timedatectl                                # clock sane -> ACME works
```

HAProxy, the WAN 80/443 rules, and the Unbound split-DNS override are **unchanged** from the oCIS build. Nothing to touch in OPNsense.

---

## 9. Phase 6 — Start

```bash
cd /opt/compose/seafile
docker compose up -d
docker compose ps
docker logs seafile -f          # watch until initialization finishes
docker logs seafile-caddy -f    # watch the Let's Encrypt issuance
```

First start creates the three databases and the admin account, so it takes noticeably longer than later starts.

Then browse to `https://cloud.dustinwalker.de` and log in with `INIT_SEAFILE_ADMIN_*`.

**Gate:** trusted LE cert in the browser; login works; a test file uploads **and downloads** (upload proves `SEAFILE_SERVER_PROTOCOL`); works on mobile data **and** home Wi-Fi.

---

## 10. Phase 7 — Post-install configuration

1. **Quotas** — admin panel → Settings: default user quota 500 GB; per-user override in the Users table (the visibility that motivated this switch).
2. **Self-registration** — confirm signup is disabled; create friend accounts manually.
3. **SMTP** — edit `/mnt/data/seafile/data/seafile/conf/seahub_settings.py` (not `.env`; Seafile has no SMTP env vars), then `docker restart seafile`:

   ```python
   EMAIL_USE_SSL = True
   EMAIL_HOST = 'smtp.zoho.eu'
   EMAIL_HOST_USER = 'notify@dustinwalker.de'
   EMAIL_HOST_PASSWORD = '<app password>'
   EMAIL_PORT = 465
   DEFAULT_FROM_EMAIL = EMAIL_HOST_USER
   SERVER_EMAIL = EMAIL_HOST_USER
   ```
4. **Clients** — install the Seafile desktop + mobile clients against `https://cloud.dustinwalker.de`. Remove every oCIS client and its old sync folders.
5. **Reboot test** — reboot VM 101 once: verify `ip route` has `default via 10.10.10.1` and **no** `169.254`, containers come back, certs persist.

---

## 11. Phase 8 — Backups (DB-first rule)

The consistency rule from [`backup-to-truenas.md`](backup-to-truenas.md) §2 is unchanged: **dump SQL first, then data.** Never overlap GC with a backup.

`/opt/compose/seafile/backup-sql.sh`:

```bash
#!/bin/bash
set -euo pipefail
cd /opt/compose/seafile
DBROOT=$(grep -E '^INIT_SEAFILE_MYSQL_ROOT_PASSWORD=' .env | cut -d= -f2-)
DEST="/mnt/data/seafile/backup-sql/$(date +%F-%H%M)"
mkdir -p "$DEST"
for db in ccnet_db seafile_db seahub_db; do
  docker exec seafile-mysql mariadb-dump -uroot -p"$DBROOT" \
    --opt --single-transaction "$db" > "$DEST/$db.sql"
done
find /mnt/data/seafile/backup-sql -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} +
```

```bash
chmod 700 /opt/compose/seafile/backup-sql.sh
```

Use `mariadb-dump` / `mariadb`, not the deprecated `mysqldump` / `mysql` wrappers (MariaDB 10.11+).

Schedule it daily (systemd timer, ~03:15), then Kopia snapshots `/mnt/data/seafile` — one job covers block store **and** the SQL dumps, so a single snapshot ID is a consistent restore set. Kopia → friend's TrueNAS remains open; see [`backup-to-truenas.md`](backup-to-truenas.md) §5.

Garbage collection (run it deliberately, never during a backup window):

```bash
docker exec -it seafile /opt/seafile/seafile-server-latest/seaf-gc.sh --dry-run
```

---

## 12. Phase 9 — Documentation to update after go-live

- [ ] [`README.md`](README.md) — replace idea-stage text with as-built (VMID, IPs, versions), status **Live**
- [ ] [`../ocis/README.md`](../ocis/README.md) — status **Decommissioned 2026-08-17**, keep for history
- [ ] [`../README.md`](../README.md) — index: `seafile/` Live, `ocis/` Decommissioned
- [ ] [`../../memory.md`](../../memory.md) — topology table, storage table, phase status, open to-do
- [ ] [`../../storage_server_setup.md`](../../storage_server_setup.md) — §2 stack, §4.1 rewrite (the plaintext-storage rationale no longer applies), §4.2 Kopia payload
- [ ] [`../../ocis-public-ingress-plan.md`](../../ocis-public-ingress-plan.md) — mark historical; ingress model survived unchanged
- [ ] [`backup-to-truenas.md`](backup-to-truenas.md) / [`disaster-restore.md`](disaster-restore.md) — drop "idea stage" framing

---

## 13. Rollback

Ordered knobs, cheapest first:

1. `docker compose down` in `/opt/compose/seafile`
2. `qm rollback 101 before-seafile-cutover` on the Proxmox host — returns the full oCIS state
3. Ingress needs no rollback: HAProxy, WAN rules, DNS and split DNS were never modified

Rollback triggers: no LE cert after DNS + `:80` verified; uploads fail while login works and `SEAFILE_SERVER_PROTOCOL` is already `https`; LAN loses Proxmox/OPNsense management.

---

## 14. Non-goals

- Full-text content search (Pro-only; accepted loss)
- SeaDoc, OnlyOffice, Collabora
- Seafile AI / face recognition
- Notification server
- IPv6
- Migrating any data out of oCIS (nothing of value stored)
- DynDNS automation (still manual; tracked in [`../../memory.md`](../../memory.md))
