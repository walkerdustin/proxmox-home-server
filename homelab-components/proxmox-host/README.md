# Proxmox host (`pve`)

**Status:** Production  
**Last verified:** 2026-08-16  
**Management:** https://192.168.1.10:8006  

Working facts: [`../../memory.md`](../../memory.md) · Rebuild networking: [`../../opnsense-rebuild-guide.md`](../../opnsense-rebuild-guide.md)

---

## 1. Role

Hypervisor for the homelab: bridges for WAN/LAN/emergency/DMZ, ZFS storage, and VMs (OPNsense, oCIS, later Dockploy).

---

## 2. Hardware

| Item | Value |
|------|--------|
| Board | MSI Z170-A PRO |
| CPU | Intel Core i5-6600K (4c/4t, AES-NI) |
| RAM | **32 GB** DDR4 (4×8 GB mixed Kingston/Corsair); typically **JEDEC 2133 MT/s** |
| Proxmox | VE **8.2.x** (no-subscription repo); kernel `7.0.14-*-pve` |
| Hostname | `pve` |

### NICs

| Name | Altname | MAC | Role / sticker |
|------|---------|-----|----------------|
| `nic0` | `enx4ccc6a6de0ed` | `4c:cc:6a:6d:e0:ed` | **EMERGENCY** (onboard) |
| `nic1` | `enx98b78524968a` | `98:b7:85:24:96:8a` | **WAN** (I350) |
| `nic2` | `enx98b78524968b` | `98:b7:85:24:96:8b` | **LAN** (I350) |

Idle I350 ports may stay `DOWN` until `ip link set nicX up`.

### Bridges

| Bridge | Port | Host IP | Notes |
|--------|------|---------|--------|
| `vmbr0` | `nic2` | `192.168.1.10/24`, gw `192.168.1.1` | Management + house LAN |
| `vmbr1` | `nic1` | *none* | WAN passthrough to OPNsense |
| `vmbr2` | `nic0` | `10.99.99.1/24` | Emergency; cable empty |
| `vmbr3` | *none* | *none* | DMZ (no host IP) |

Emergency laptop: static `10.99.99.2/24`, no gateway → `https://10.99.99.1:8006`.

---

## 3. Storage (host)

| Pool | Topology | Use |
|------|----------|-----|
| `rpool` | ZFS mirror | OS, VM OS disks |
| `tank` | RAIDZ1 (3× ~2 TB HDD) | Large data VDisks (oCIS `scsi1` ~3 TB) |

**`rpool` disks**

| Disk | Serial | Notes |
|------|--------|--------|
| Samsung 850 EVO 250GB | `S2CJNXAG514758J` | mirror member |
| Samsung 860 EVO 500GB | `S3Z2NB0KA29651E` | mirror member |
| ESPs | `A0B2-D849`, `041E-0F11` | both bootable |

Also present: ~120 GB Crucial (planned local backup target later).

**Drive SMART / temps:** Scrutiny hub–spoke — [`../scrutiny/`](../scrutiny/) (LXC 102 + host collector). Scrutiny is **not** the ZFS email path below.

**ZFS tuning (intent)**

- Compression on (lz4/zstd); **dedup off**
- ARC cap ~**4 GB** when HDD pool is busy (reserve RAM for VMs)
- `sync=standard` (no UPS)
- No HDD spindown for ZFS members

Detail: [`../../storage_server_setup.md`](../../storage_server_setup.md)

### ZFS / pool email alerts (Zoho SMTP)

Set up **2026-08-15** so RAIDZ1/`rpool` problems mail you (degraded pool, scrub errors, etc.) via Proxmox **Datacenter → Notifications**. This is separate from Scrutiny (temps/history UI; Scrutiny email alerts still optional).

| Item | Value |
|------|--------|
| Target name | `zoho-smtp` |
| SMTP server | **`smtp.zoho.eu`** (not `smtppro` — free/custom-domain mailbox) |
| Encryption / port | TLS / **465** |
| Auth user / From | `zfs.notification@dustinwalker.de` |
| Password | Zoho mailbox password or **App Password** (if 2FA) — not in git |
| Additional recipient | `mail@dustinwalker.de` |
| Matcher | Default matcher includes **`zoho-smtp`**; **`mail-to-root`** left off (no local MTA) |

**DNS on host (required for SMTP):** resolvers must reach Zoho. Under `vmbr0`:

```text
dns-nameservers 192.168.1.1 1.1.1.1
dns-search local
```

If Test fails with “Temporary failure in name resolution”, fix `/etc/resolv.conf` / those lines first.

**Verify:** Datacenter → Notifications → `zoho-smtp` → **Test** → mail arrives at `mail@dustinwalker.de`.

**Weekly `tank` scrub** (errors surface via ZED/Proxmox notifications):

```bash
# /etc/cron.d/zfs-scrub-tank — Sundays 03:00
0 3 * * 0 root zpool scrub tank
```

(Confirm file still present after rebuilds: `cat /etc/cron.d/zfs-scrub-tank`.)

---

## 4. VMs / CTs on this host

| VMID | Name | Role | Status |
|------|------|------|--------|
| 100 | `opnsense` | Edge router / firewall / HAProxy | Live — [`../opnsense/`](../opnsense/) |
| 101 | `ocis` | File cloud | Live — [`../ocis/`](../ocis/) |
| 102 | `scrutiny` | SMART / temp hub (LXC) | Live — [`../scrutiny/`](../scrutiny/) |
| *(later)* | Dockploy | Public apps | Planned — [`../dockploy/`](../dockploy/) |

No CPU pinning; OPNsense uses high CPU weight (4096). OPNsense **Start at boot = Yes**.

---

## 5. Day-2 ops

```bash
# Host networking
ip -br a
bridge link
cat /etc/network/interfaces

# Guests
qm list
pct list
qm config 100 | grep -E '^(net|memory|onboot)'
qm config 101 | grep -E '^(net|memory|scsi|onboot)'

# Guest agent when SSH to DMZ fails
qm guest exec 101 -- ip -br a

# Mail / ZFS
# UI: Datacenter → Notifications → zoho-smtp → Test
zpool status
zpool scrub -s tank   # status of scrub if running
```

**Backups:** Prefer VM/ZFS snapshots before risky changes. Do not put OPNsense XML in git.

---

## 6. Common failures

| Symptom | Fix / note |
|---------|------------|
| Lost Proxmox UI after bridge Apply | Emergency `nic0` / dual-cable method in cutover docs |
| No link lights on I350 | `ip link set nic1 up` / `nic2 up` |
| DMZ VM unreachable | Check guest static IP + no `169.254`; OPNsense DMZ rules |
| `zoho-smtp` Test: name resolution | Host DNS still wrong — `192.168.1.1` / `1.1.1.1` on `vmbr0` |
| `zoho-smtp` Test: auth / 554 | Use **`smtp.zoho.eu`** (not smtppro); App Password if 2FA |
| No pool emails | Matcher must include `zoho-smtp`; confirm ZFS events matched |
