# StorageServerSetup

## 1. Context & Objectives
This document outlines the architecture, configuration, and design choices for the File Storage VM (VM 3) on a Proxmox VE host. The Proxmox host and the OPNsense router/firewall are already configured. 
The goal of this VM is to provide a private cloud and backup storage for the administrator and friends (500 GB quota per user) using **Seafile 13 Community Edition**, with an automated, encrypted offsite backup to a remote TrueNAS system using **Kopia**.

> **Application changed 2026-08-17:** oCIS was replaced by Seafile on this same
> VM. Sections 3 and 5 (ZFS, local DR) are unaffected — the pool and the vdisk
> were reused as-is. Section 4.1 has been rewritten; the previous
> oCIS rationale is preserved there as a footnote because its argument against
> block storage was the very objection this switch had to answer.
> As-built: [`homelab-components/seafile/README.md`](homelab-components/seafile/README.md).

## 2. Virtual Machine Specifications (VM 101, guest hostname still `ocis`)
*   **OS:** Debian Linux (headless).
*   **Resources:** 6 GB RAM, 2 vCPU.
*   **Network:** DMZ bridge `vmbr3` — static `10.10.10.10/24`, gateway OPNsense DMZ `10.10.10.1` (not LAN).
*   **Software Stack:** Docker Compose — official **Seafile CE 13.0** (`seafile-server.yml` + `caddy.yml`): Seafile + MariaDB 10.11 + Redis + Caddy. **SeaDoc, notification server and Seafile AI off.**
*   **Public URL:** `https://cloud.dustinwalker.de` (HAProxy SNI passthrough from OPNsense; TLS on **Caddy**).
*   **Ingress plan:** See [`ocis-public-ingress-plan.md`](ocis-public-ingress-plan.md) — written for oCIS/Traefik, but the model is unchanged and still accurate.

## 3. Storage Architecture & ZFS Configuration (Host Level)
The storage backend relies on a ZFS pool managed by the Proxmox host.
*   **Hardware:** 3x 2 TB HDDs.
*   **Topology:** RAIDZ1 (1 disk parity).
*   **Virtual Disk:** A single large virtual disk (~3.5 TB, `.raw` format) is created on the RAIDZ1 pool and passed to VM 3.
*   **Future Expansion:** The pool is designed to be expanded later with a 4th 2TB HDD using the OpenZFS 2.3 "RAIDZ Expansion" feature.

### 3.1 ZFS Tuning (Performance & Reliability Choices)
*   **Compression:** `ON` (lz4 or zstd). *Reason: Reduces write I/O on HDDs with near-zero CPU overhead.*
*   **Deduplication:** `OFF` (Strictly disabled). *Reason: Prevents RAM exhaustion. The host only has 32GB RAM total, and encrypted/media files do not benefit from block-level deduplication.*
*   **ARC Limit:** Hard-limited to ~4 GB on the Proxmox host. *Reason: Reserves RAM for the VMs (specifically a vector database in another VM).*
*   **Caching (L2ARC / SLOG):** None. *Reason: Consumer SSDs are used. Network upload speed is the bottleneck, making ZFS RAM caching (asynchronous writes) sufficient.*
*   **Sync:** `sync=standard`. *Reason: No UPS is present. Ensures data integrity during unexpected power loss.*

## 4. Application Stack (Docker in VM 3)

### 4.1 Seafile 13 CE (Primary File Server)
*   **Why Seafile?** The admin UI exposes a per-user **usage / quota / last-login table** plus stats. oCIS offered no equivalent outside its API, and that visibility is the whole reason for the 2026-08-17 switch.
*   **Storage Format:** Content-addressed **block store** (`blocks` / `fs` / `commits`) plus **three MariaDB databases** (`ccnet_db`, `seafile_db`, `seahub_db`). Files are *not* browsable as plaintext on the pool.
*   **Split-brain mitigation:** The DB↔blocks desync risk is real and is answered procedurally, not architecturally — always **dump SQL first, then data**, so the restored DB can only reference blocks that already exist; never overlap garbage collection with a backup; `seaf-fsck` after any restore. Nightly dumps land on `tank` beside the block store so one Kopia snapshot is a consistent set. Full rationale: [`homelab-components/seafile/backup-to-truenas.md`](homelab-components/seafile/backup-to-truenas.md) §2.
*   **Bare-metal file recovery:** No longer a plain file copy. `seaf-fsck --export` reconstructs real files from `seafile-data` **without** the databases — an emergency path, not a running server. Encrypted libraries still need their per-library passphrase.
*   **Database placement:** Live MariaDB sits on the **SSD** OS disk (`/opt/seafile-mysql/db`), not on `tank`. *Reason: the RAIDZ1 HDD pool has no SLOG and `sync=standard`, so every InnoDB commit would pay a full HDD round-trip and Seahub is commit-chatty.*
*   **User Experience:** Native Seafile desktop and mobile clients against `https://cloud.dustinwalker.de`.
*   **Quotas:** 500 GB per user — a default in the admin Settings, overridable per user in the Users table.
*   **Privacy:** Trust-based by default. Seafile's own encrypted libraries are available per library; users wanting zero-knowledge beyond that still bring their own tooling (e.g. Cryptomator).
*   **Known limitation:** **No full-text content search.** CE indexes file and folder names only; content search is Professional-only (free ≤ 3 users, which does not fit the friends plan). This replaced a working oCIS + Tika content search and was accepted deliberately.

> **Superseded oCIS rationale (kept deliberately):** the previous design chose
> oCIS for its Go footprint, absence of any external database, and **plaintext**
> on-disk layout, explicitly to avoid the block-store split-brain risk named
> above. That argument was never wrong — the switch accepts more backup
> choreography and a harder bare-metal recovery path in exchange for admin
> visibility. If the DB-first discipline or the monthly restore drill ever
> lapses, this is the paragraph that predicted the consequence.

### 4.2 Kopia (Offsite Backup)
*   **Role:** Automated, encrypted offsite backup to a friend's TrueNAS system (via SFTP or S3/MinIO). **Status: still open** — only the local nightly SQL dumps exist so far.
*   **Payload:** `/mnt/data/seafile` — the block store **and** `backup-sql/`. Both must be in the same snapshot, or the restore set is incomplete.
*   **Ordering:** Runs **after** the nightly `mariadb-dump` (`seafile-backup-sql.timer`, 03:15), never concurrently with garbage collection.
*   **Deployment:** Runs as a secondary Docker container alongside Seafile.
*   **Security Design Choice:** The Seafile data directory is mounted as **Read-Only** into the Kopia container to prevent accidental data deletion by the backup tool.
*   **Backup Mechanics:** Client-side AES-256 encryption, block-level deduplication, and incremental uploads.
*   **Disaster Recovery:** Kopia maintains a local cache for performance, but the master index is stored on the TrueNAS target. If VM 3 is completely destroyed, the backup can be restored from any machine using the repository password.

## 5. Local Disaster Recovery (Proxmox Level)
To protect against ransomware, accidental deletion, or failed updates, local disaster recovery is handled outside the VM:
*   **ZFS Snapshots:** Automated daily ZFS snapshots of the VM 3 virtual disk on the Proxmox host (e.g., using `sanoid`).
*   **Retention:** 7 days. *Reason: Keeps storage overhead low (estimated 5-10%) while providing a 1-second rollback capability.*
*   **OS Backup:** The OS disk of VM 3 (located on the Proxmox SSD) is backed up regularly using the native Proxmox backup utility to a dedicated, isolated SSD on the host.
