# Seafile (idea stage)

**Status:** Idea / evaluation only — **not installed**  
**Last updated:** 2026-08-16  

Current live file cloud: [`../ocis/`](../ocis/). This folder captures research if we **switch** (or dual-run) Seafile mainly for admin UX (per-user usage, quotas, statistics), with a workable offsite backup to a friend’s TrueNAS.

---

## 1. Why this folder exists

Frustration with oCIS admin visibility (no Seafile-like user usage/quota table or stats dashboard) led to reconsidering Seafile. The historical objection was backup complexity (block store + databases). Research conclusion: **solvable** with a strict dump order + encrypted incremental tool (Kopia/Restic) to TrueNAS — harder than oCIS, not a blocker if restore drills are done.

**No migration decision has been made.** Do not treat this as an install guide until status changes to Planned/Live.

---

## 2. Docs in this folder

| File | Contents |
|------|----------|
| [`README.md`](README.md) | This index — idea status, tradeoffs, open questions |
| [`backup-to-truenas.md`](backup-to-truenas.md) | Storage model, backup lifecycle, tools, edge cases |
| [`disaster-restore.md`](disaster-restore.md) | Full host loss → rebuild Proxmox → restore from TrueNAS |

Related live architecture: [`../../storage_server_setup.md`](../../storage_server_setup.md) (Kopia→TrueNAS was already planned for oCIS).

---

## 3. Tradeoff snapshot (idea stage)

| Topic | Seafile (idea) | oCIS (live today) |
|-------|----------------|-------------------|
| Admin: users / usage / quota / stats | Strong (product UI) | Weak; quotas via Spaces; usage via API/`df`/`zfs` |
| Backup components | **3 MariaDB DBs + block/fs/commits tree** | Config + data tree; no MySQL trio |
| Backup consistency rule | **DB dump first**, then data (official) | Stop instance or **ZFS snapshot**, then copy |
| Offsite to friend TrueNAS | Kopia/Restic encrypted over SFTP/MinIO | Same tools, simpler payload |
| Incremental | Excellent (immutable blocks) | Excellent (file/chunk dedupe) |
| Encrypted offsite | Client-side (Kopia/Restic) — required | Same |
| Restore difficulty | Higher (SQL + paths + `seaf-fsck`) | Lower |
| Monthly verify | Throwaway VM + SQL + fsck + UI | Throwaway restore of data tree + UI |

---

## 4. Locked assumptions (if we ever implement)

- Deploy in **DMZ** (same pattern as oCIS): HAProxy SNI/Host → VM `:443`/`:80`.  
- Data on **`tank`** (or successor HDD pool).  
- Offsite: **friend’s TrueNAS**, **client-side encrypted** repo (not plaintext rsync).  
- Tool preference: **Kopia** (already in storage plan) or **Restic** (Datamate Seafile docs use Restic).  
- **Monthly restore drill is non-negotiable.**

---

## 5. Open questions (before any migration)

- [ ] Keep oCIS and add Seafile, or replace?  
- [ ] Hostname(s) / DNS if replacing `cloud.dustinwalker.de`  
- [ ] Friend’s TrueNAS: SFTP dataset vs MinIO bucket; quota; access from our WAN/LAN  
- [ ] Initial seed strategy (USB drive vs multi-day WAN upload)  
- [ ] Accept RPO = “since last successful backup window” (DB-first loses in-flight uploads)  
- [ ] Encrypted Seafile libraries: passphrase management for friends  

---

## 6. Explicit non-goals (idea stage)

- No compose files or secrets in this folder yet  
- No cutover from oCIS  
- No production Seafile VM ID reserved  

When this leaves idea stage, replace this README with as-built placement (VMID, IPs, versions) like [`../ocis/`](../ocis/).
