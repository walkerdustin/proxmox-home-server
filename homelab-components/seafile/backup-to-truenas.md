# Seafile → friend’s TrueNAS backup (idea stage)

**Status:** Idea / research notes — not implemented  
**Last updated:** 2026-08-16  
**Primary sources:** [Seafile Backup and Recovery](https://manual.seafile.com/latest/administration/backup_recovery/), [Seafile FSCK](https://manual.seafile.com/latest/administration/seafile_fsck/), Datamate Restic extension docs, community Kopia/Borg/rsync threads  

Parent: [`README.md`](README.md) · Disaster path: [`disaster-restore.md`](disaster-restore.md)

---

## 1. What must be backed up

Seafile always has **two** classes of data (official):

| Part | Typical names | Holds |
|------|----------------|--------|
| Databases | `ccnet_db`, `seafile_db`, `seahub_db` | Users/groups; library metadata/heads; web UI / shares |
| Library data | Docker: under `/opt/seafile-data/seafile/` (`conf`, `seafile-data`, `seahub-data`) | Blocks, fs objects, commits, config |

**Assumption checked:** Backing up only the block store is **not** a full product backup.  
**Assumption checked:** With **only** `seafile-data`, [seaf-fsck export](https://manual.seafile.com/latest/administration/seafile_fsck/) can recover **files to a normal filesystem** without the DB — emergency, not a running Seafile.

**Assumption checked:** Blocks are content-addressed and normally **immutable** (add/GC-delete). That makes incremental sync/backup tools efficient after the first full run.

---

## 2. Consistency rule (non-negotiable)

Official order tradeoff:

| Order | On restore |
|--------|------------|
| Data first, DB later | DB may reference **missing** blocks → **library corruption** |
| **DB first, data later** (recommended) | DB only references existing blocks → **no corruption**; uploads during the window may be **lost** (orphan blocks OK) |

**Policy for this idea:** always **dump DBs first**, then back up data (ideally from a **ZFS snapshot** of the data volume taken right after the dump).

Also:

- Do **not** run **garbage collection** during the data backup.  
- `mariadb-dump` / `mysqldump` locks tables briefly; official docs say Seafile need not be stopped for the dump.  
- Live multi-hour rsync without a snapshot can still race; prefer snapshot-then-backup for large datasets.

---

## 3. Requirements mapping

| Requirement | Approach |
|-------------|----------|
| Incremental | Kopia or Restic (chunk dedupe); Seafile blocks change little after first full |
| Encrypted | **Client-side** repo encryption (friend must not see plaintext) |
| Reliable | DB-first + same-run SQL+data in one snapshot; `seaf-fsck` after restore; **monthly drill** |
| Easy restore | Documented runbook ([`disaster-restore.md`](disaster-restore.md)); Docker path nesting is a known footgun |
| Easy setup | One systemd timer + small dump script; TrueNAS SFTP (simplest) or MinIO |

**Rejected for offsite:** plaintext `rsync` to friend’s NAS as the only copy.

---

## 4. Target on friend’s TrueNAS

| Option | Pros | Cons |
|--------|------|------|
| **SFTP** dataset + dedicated user | Simple; Kopia/Restic support well | Friend manages SSH user/keys |
| **MinIO (S3)** on TrueNAS | Nice for object repos; optional object-lock | Extra service to maintain |
| Borg server on TrueNAS | Excellent over SSH | Often custom; less “click to install” on TrueNAS |

**Idea default:** SFTP dataset `seafile-backup` (or `cloud-backup`) with quota ≥ data size × retention factor; access limited; **Kopia** repo password only on our side.

---

## 5. Proposed nightly lifecycle

```text
[Seafile VM, DMZ]
  1. Ensure GC is not running
  2. mariadb-dump ×3 → e.g. /opt/seafile-data/backup-sql/YYYY-mm-dd-HHMM/
       (keep local copies ≥ 7–30 days; never overwrite single file forever)
  3. Optional but preferred: ZFS snapshot of Seafile data VDisk on Proxmox
  4. kopia snapshot create  (paths: seafile data tree + backup-sql/)
       → sftp://friend-truenas/…  (AES, password in password manager)
  5. kopia policy: keep 7 daily / 4 weekly / 6 monthly (tune later)
  6. On failure → email (Zoho notify mailbox)
```

Community pattern (aligned): dump SQL **into** a folder next to data, then one Kopia job covers both so a single snapshot ID is a consistent restore set.

Datamate documents a similar idea with **Restic** for Docker Seafile (encrypted, deduped, scheduled). Either tool is fine; prefer **one** and stick to it.

---

## 6. Full lifecycle (ops)

### Install / first backup

1. Friend: dataset + SFTP (or MinIO).  
2. Us: install Kopia (or Restic) on Seafile VM or Proxmox host (host can snapshot easier).  
3. `kopia repository create` / connect; store password offline.  
4. Run dump script once; first snapshot (may take days over WAN — consider USB seed).  
5. Schedule timer; verify second incremental is small/fast.  
6. **Immediately** do a throwaway restore drill once.

### Steady state

- Nightly (or 2× daily) dump + snapshot.  
- Weekly check: last snapshot age, job logs, disk temps (Scrutiny).  
- Monthly: [`disaster-restore.md`](disaster-restore.md) Phase 2–3 on a disposable VM.

### Restore (product)

1. Restore **one** Kopia snapshot (SQL folder + data tree together).  
2. Place data in correct Docker paths.  
3. Import three SQL files.  
4. Start Seafile → `seaf-fsck` → UI + client test.

### Restore (files only)

- `seaf-fsck` export from `seafile-data` if DBs are gone.  
- Encrypted libraries need user **library passphrases**.

---

## 7. Edge cases checklist

| Edge case | Risk | Mitigation |
|-----------|------|------------|
| GC during backup | Missing/deleted blocks mid-copy | Never overlap GC and backup |
| Uploads during backup | Lost newest files (RPO) | Accepted with DB-first; optional maintenance window |
| Wrong Docker `seafile-data` nesting | Broken shares/UI after restore | Follow current official Docker paths; dry-run |
| Encrypted libraries | Unreadable without passphrase | Document; separate from account password |
| Friend’s NAS dies | Offsite gone | Second copy (USB / other) — 3-2-1 |
| Repo password lost | Backups useless | Password manager + sealed offline copy |
| Only rsync, no crypto | Friend can read data | Forbidden for this design |
| Huge first backup | Days on WAN | USB seed or local LAN initial sync |
| `seaf-fsck --repair` | Rolls to older consistent commit | Expected after split window |
| MariaDB volume separate from data VDisk | Incomplete backup set | Include **both** mounts in dump/paths |
| Docs used deprecated `mysql*` on MariaDB 10.11+ | Dump fails | Use `mariadb-dump` / `mariadb` (official tip) |

---

## 8. Comparison: same TrueNAS target with live oCIS

| | Seafile (idea) | oCIS (live) |
|--|----------------|-------------|
| Payload | 3 SQL dumps + block tree | `/mnt/data/ocis` (+ config); embedded stores |
| Consistency | DB-first choreography | Stop or ZFS snap, then Kopia |
| Tooling | Kopia/Restic identical | Already planned in [`../../storage_server_setup.md`](../../storage_server_setup.md) |

Switching for admin UX **increases** backup choreography cost; it does **not** require abandoning Kopia→TrueNAS.

---

## 9. Idea-stage open to-do (backup only)

- [ ] Agree SFTP vs MinIO with friend  
- [ ] Choose Kopia vs Restic  
- [ ] Draft dump script + systemd timer (when leaving idea stage)  
- [ ] Define retention policy numbers  
- [ ] First restore drill on disposable VM  
- [ ] Document library encryption policy for friends  
