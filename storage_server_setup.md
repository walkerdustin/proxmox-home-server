# StorageServerSetup

## 1. Context & Objectives
This document outlines the architecture, configuration, and design choices for the File Storage VM (VM 3) on a Proxmox VE host. The Proxmox host and the OPNsense router/firewall are already configured. 
The goal of this VM is to provide a private cloud and backup storage for the administrator and friends (500 GB quota per user) using **ownCloud oCIS**, with an automated, encrypted offsite backup to a remote TrueNAS system using **Kopia**.

## 2. Virtual Machine Specifications (VM 101 `ocis`)
*   **OS:** Debian Linux (headless).
*   **Resources:** 6 GB RAM, 2 vCPU.
*   **Network:** DMZ bridge `vmbr3` — static `10.10.10.10/24`, gateway OPNsense DMZ `10.10.10.1` (not LAN).
*   **Software Stack:** Docker Compose — official **oCIS `ocis_full`** (Traefik + Let’s Encrypt + Tika; **Collabora off**).
*   **Public URL:** `https://cloud.dustinwalker.de` (HAProxy SNI passthrough from OPNsense; TLS on Traefik).
*   **Ingress plan:** See [`ocis-public-ingress-plan.md`](ocis-public-ingress-plan.md).

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

### 4.1 ownCloud oCIS (Primary File Server)
*   **Why oCIS?** Go-based, extremely low RAM footprint, microservice architecture, and requires **no external database** (no MariaDB/Redis).
*   **Storage Format:** Files are stored in **plaintext** on the virtual disk. *Reason: Eliminates the "split-brain" risk of block-storage systems (like Seafile) where database and data blocks can desync. Allows bare-metal recovery of files directly from the ZFS pool if the VM dies.*
*   **User Experience:** Users connect via native desktop clients utilizing Virtual File System (VFS) APIs (Files-on-Demand).
*   **Quotas:** Hard quotas of 500 GB per user configured via oCIS Spaces.
*   **Privacy:** Trust-based. No native server-side E2EE is enforced. Users must use third-party tools (e.g., Cryptomator) locally if they require zero-knowledge encryption.

### 4.2 Kopia (Offsite Backup)
*   **Role:** Automated, encrypted offsite backup to a friend's TrueNAS system (via SFTP or S3/MinIO).
*   **Deployment:** Runs as a secondary Docker container alongside oCIS.
*   **Security Design Choice:** The oCIS data directory is mounted as **Read-Only** into the Kopia container to prevent accidental data deletion by the backup tool.
*   **Backup Mechanics:** Client-side AES-256 encryption, block-level deduplication, and incremental uploads.
*   **Disaster Recovery:** Kopia maintains a local cache for performance, but the master index is stored on the TrueNAS target. If VM 3 is completely destroyed, the backup can be restored from any machine using the repository password.

## 5. Local Disaster Recovery (Proxmox Level)
To protect against ransomware, accidental deletion, or failed updates, local disaster recovery is handled outside the VM:
*   **ZFS Snapshots:** Automated daily ZFS snapshots of the VM 3 virtual disk on the Proxmox host (e.g., using `sanoid`).
*   **Retention:** 7 days. *Reason: Keeps storage overhead low (estimated 5-10%) while providing a 1-second rollback capability.*
*   **OS Backup:** The OS disk of VM 3 (located on the Proxmox SSD) is backed up regularly using the native Proxmox backup utility to a dedicated, isolated SSD on the host.
