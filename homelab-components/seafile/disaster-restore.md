# Disaster restore: new disks → Proxmox → Seafile from TrueNAS

**Status:** Runbook draft — **not yet tested** on this homelab  
**Last updated:** 2026-08-17  
**Assumes:** Nightly **DB-first** dumps (live since 2026-08-17) + Seafile data in an **encrypted Kopia (or Restic) repo** on friend’s TrueNAS — the repo half is **still open**, so today this runbook is only executable from local dumps ([`backup-to-truenas.md`](backup-to-truenas.md))

Parent: [`README.md`](README.md)

---

## 0. Scenario

> HDD data corrupted **and** SSD RAID (`rpool`) dies.  
> Wipe HDD pool, install **two new SSDs**, rebuild Proxmox, restore Seafile from offsite.

| Lost | Still available |
|------|-----------------|
| Proxmox OS / VMs on `rpool` | Friend TrueNAS + Kopia/Restic repo |
| `tank` Seafile data | Repo password, SFTP/MinIO credentials |
| Live MariaDB | This runbook + Seafile Docker notes |

**Verify (non-negotiable):** Monthly, restore latest snapshot to a **throwaway VM**, import SQL, run `seaf-fsck`, open UI. Untested backup = hope. That drill is a dress rehearsal of Phases 2–3 below.

---

## 1. Phase 0 — Prep

1. From another machine: confirm TrueNAS up; `kopia snapshot list` / `restic snapshots` works.  
2. Prefer a **known-good** snapshot if the newest might include corruption window.  
3. Have ready: Proxmox ISO, network plan (LAN/WAN/DMZ), Seafile compose version notes, **repo password**, SSH keys, DNS/HAProxy notes.  
4. Hardware: two SSDs for `rpool`; HDDs wiped/replaced for `tank`.

---

## 2. Phase 1 — Rebuild Proxmox

1. Install Proxmox on new SSD mirror (`rpool`).  
2. Recreate bridges (`vmbr0` LAN, WAN, DMZ, emergency as before).  
3. Recreate empty **`tank`** (RAIDZ1 or chosen topology).  
4. Host management IP + DNS working.  

Hypervisor is blank; no Seafile yet.

---

## 3. Phase 2 — Pull backup onto the new host

On Proxmox or a small restore helper:

```text
kopia repository connect sftp://…   # friend’s TrueNAS
kopia snapshot list
kopia restore <snapshot-id> /mnt/restore/seafile-backup/
```

Expect (names may vary):

```text
…/backup-sql/     ccnet_db.sql.*  seafile_db.sql.*  seahub_db.sql.*
…/seafile/        conf, seafile-data, seahub-data   # Docker-oriented layout
```

**Bottleneck:** multi‑TB restore over WAN can take **hours–days**. USB seed from friend is valid for first recovery.

---

## 4. Phase 3 — New Seafile stack, then fill

1. Create VM on `tank` (DMZ IP, Docker).  
2. Deploy **fresh** official Seafile Docker stack so MariaDB and bind mounts exist.  
3. Stop Seafile app containers; keep DB up for import.  
4. Restore **data directory** into the **correct** host path  
   (current official Docker recovery uses rsync into `/opt/seafile-data/seafile/` — trailing slashes and nesting matter; see [Backup and Recovery](https://manual.seafile.com/latest/administration/backup_recovery/)).  
5. Import the **three** SQL dumps from the **same** snapshot into `ccnet_db`, `seafile_db`, `seahub_db` (`mariadb` client on modern images).  
6. Fix ownership if required; start Seafile.  
7. Run **`seaf-fsck`** (repair if needed).  
8. UI login + open library + desktop client.  
9. Re-point HAProxy/DNS to the new VM.

### Success criteria

- [ ] Users can log in  
- [ ] Libraries open; sample download works  
- [ ] `seaf-fsck` clean or repaired with understood RPO loss  
- [ ] Only then delete restore scratch and re-enable nightly backup  
- [ ] Schedule next monthly drill  

---

## 5. Rough timing

| Step | Order of magnitude |
|------|--------------------|
| Proxmox + network + empty `tank` | Hours |
| Kopia restore of large dataset | Hours–days (link limited) |
| SQL import + fsck + smoke test | &lt; 1 hour once data is local |

---

## 6. Edge cases in this scenario

| Situation | Action |
|-----------|--------|
| Latest snapshot suspect | Restore previous good snapshot |
| Encrypted libraries | Users need library passphrases |
| SQL from different night than data | Inconsistency → prefer matching snapshot; then fsck |
| Wrong Docker path | Empty/broken libraries — fix path, re-copy |
| Friend / TrueNAS offline | Blocked until offsite reachable |
| Files-only salvage | `seaf-fsck` export without full product restore |

---

## 7. If we stay on oCIS instead (same hardware loss)

Phases 0–2 identical (repo might be named `ocis-backup`).  
Phase 3: new oCIS VM → restore `/mnt/data/ocis` (+ config) from **one** Kopia snapshot → start stack → UI. **No** three-DB import; consistency still depends on backup having been taken from stop or ZFS snapshot ([oCIS backup docs](https://doc.owncloud.com/ocis/latest/admin/maintenance/b-r/backup.html)).

---

## 8. Idea-stage note

This runbook is **untested** on this homelab until Seafile is installed and a drill is logged. When first drill succeeds, record date + snapshot ID + duration here and flip parent status toward Planned/Live.
