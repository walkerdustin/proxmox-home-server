# Proxmox host (`pve`)

**Status:** Production  
**Last verified:** 2026-08-22  
**Management:** https://192.168.1.10:8006  

Working facts: [`../../memory.md`](../../memory.md) · Rebuild networking: [`../../opnsense-rebuild-guide.md`](../../opnsense-rebuild-guide.md)

---

## Schedules (authoritative)

Every recurring job that touches this host or VM 101. All times **Europe/Berlin**.
If another doc disagrees with this table, this table wins.

| When | Job | Runs on | Defined in |
|------|-----|---------|------------|
| every 15 min | `sanoid` evaluates retention — only acts when a policy is actually due | `pve` | `sanoid.timer` (package default) + [`configs/sanoid.conf`](configs/sanoid.conf) |
| hourly | Snapshot `tank/vm-101-disk-0` (12 kept) | `pve` | sanoid `template_seafiledata` |
| **03:15** daily | Seafile MariaDB dumps -> `/mnt/data/seafile/backup-sql/`, 14-day retention | **VM 101** | `seafile-backup-sql.timer` (`Persistent=true`) |
| **04:00** daily | Snapshot `tank/vm-101-disk-0` (7 daily, 2 weekly) | `pve` | sanoid `template_seafiledata` |
| **04:10** daily | Snapshot `rpool/data/vm-101-disk-1` (7 daily) | `pve` | sanoid `template_vmos` |
| **:25** hourly | ZFS capacity check, both pools | `pve` | [`configs/cron.d-zfs-capacity-alert`](configs/cron.d-zfs-capacity-alert) |
| **:00 / :20 / :40** | Drive temperature check, all 6 disks | `pve` | [`configs/cron.d-drive-temp-alert`](configs/cron.d-drive-temp-alert) |
| *interval unverified* | Scrutiny collector pushes SMART data to LXC 102 | `pve` | systemd timer — check: `systemctl list-timers 'scrutiny*'` |
| **Sun 03:00** weekly | `zpool scrub tank` | `pve` | `/etc/cron.d/zfs-scrub-tank` |
| weekly (Mon) | `fstrim` — returns freed guest blocks to ZFS | **VM 101** | `fstrim.timer` (systemd default) |
| *manual only* | Seafile `seaf-gc.sh` — must **never** overlap a backup or dump | VM 101 | — |
| *unverified* | `rpool` scrub — Debian's zfsutils cron may or may not be present | `pve` | check: `ls /etc/cron.d/` |

**The 03:15 / 04:00 ordering is deliberate**, not incidental: the guest dumps its databases
*before* the data zvol is snapshotted, so every daily snapshot contains the block store **and**
a matching SQL dump = one self-consistent restore set. Do not reorder these.

## Notifications (authoritative)

All mail lands at `mail@dustinwalker.de`. Senders: `zfs.notification@dustinwalker.de` (host)
and the `cloud@dustinwalker.de` alias (Seafile) -- **both draw on one Zoho per-user quota**.

| Event | Detected by | Transport | State |
|-------|-------------|-----------|-------|
| Pool degraded / faulted / checksum errors | ZED | `mail` -> postfix -> `/root/.forward` -> `proxmox-mail-forward` -> `zoho-smtp` | Path proven 2026-08-22. A real DEGRADED event was never staged -- `zinject` is not shipped by Proxmox |
| **Every scrub finish**, clean or not | ZED, `ZED_NOTIFY_VERBOSE=1` | same as above | **Verified 2026-08-22.** Doubles as a weekly **heartbeat** for this entire chain |
| Pool nearly full (alloc >= 85%, or `AVAIL` below floor) | `zfs-capacity-alert.sh` | **`curl` straight to `smtp.zoho.eu:465`** -- deliberately independent of postfix and pmxcfs | Verified 2026-08-18 |
| Proxmox jobs, and Notifications -> **Test** | PVE notification system | PVE's own SMTP client -> Zoho | Working |
| Anything doing `mail root` (cron, smartd) | postfix | mail-to-root path | Verified 2026-08-22 |
| Seafile app mail (shares, password reset) | Seahub | `seahub_settings.py` -> `smtp.zoho.eu:465` via `cloud@` alias | Verified 2026-08-18 |
| **Drive temperature** over ceiling | `drive-temp-alert.sh` | `curl` straight to `smtp.zoho.eu:465` | Verified 2026-08-22. HTML table of **all** drives every mail |
| **SMART: reallocated / pending sectors, self-test failures** | Scrutiny collects it, nothing alerts on it | — | **GAP** -- growing bad sectors predict failure better than temperature does, and ZFS reports `ONLINE` throughout |
| **Nightly SQL dump fails** | — | **nothing** | **GAP** -- a failing timer is silent. Needs `OnFailure=` or a check in the capacity script |

**Two transports, and they fail independently.** The Notifications **Test** button uses PVE's
own SMTP client; ZED uses local `mail`. A passing Test proves nothing about ZED. This is not
theoretical -- see the `aliases.db` incident in the ZED section below.

```bash
# is the alert plumbing alive?
ls -l /etc/aliases.db /usr/libexec/proxmox-mail-forward   # both must exist
mailq                                                    # must say "Mail queue is empty"
grep ZED_NOTIFY_VERBOSE /etc/zfs/zed.d/zed.rc            # must be =1
systemctl list-timers sanoid.timer                       # next run in the future
stat -c '%y  %n' /var/lib/zfs-capacity-alert/*           # mtimes must advance hourly
```

---

## 1. Role

Hypervisor for the homelab: bridges for WAN/LAN/emergency/DMZ, ZFS storage, and VMs (OPNsense, Seafile, later Dockploy).

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
| `tank` | RAIDZ1 (3× ~2 TB HDD) | Large data VDisks (VM 101 `scsi1` ~3 TB, guest `/mnt/data`) |

**`rpool` disks**

| Disk | Serial | Notes |
|------|--------|--------|
| Samsung 850 EVO 250GB | `S2CJNXAG514758J` | mirror member |
| Samsung 860 EVO 500GB | `S3Z2NB0KA29651E` | mirror member |
| ESPs | `A0B2-D849`, `041E-0F11` | both bootable |

Also present: ~120 GB Crucial (planned local backup target later).

**VM 101 zvols — do not confuse the two `vm-101-disk-0` names:**

| Dataset | Role |
|---------|------|
| `rpool/data/vm-101-disk-0` | **EFI disk** (`efidisk0`, 1M) — tiny, looks orphaned, **destroying it breaks UEFI boot** |
| `rpool/data/vm-101-disk-1` | OS disk `scsi0` (32G) — also holds the live MariaDB |
| `tank/vm-101-disk-0` | Data disk `scsi1` (3000 GiB, thick) — `/mnt/data` in the guest |

`qm config 101` filtered on `scsi|virtio|sata|ide` hides `efidisk0`; always grep `/etc/pve/nodes/pve/qemu-server/101.conf` before destroying any zvol.

**Drive SMART / temps:** Scrutiny hub–spoke — [`../scrutiny/`](../scrutiny/) (LXC 102 + host collector). Scrutiny is **not** the ZFS email path below.

**ZFS tuning (intent)**

- Compression on (lz4/zstd); **dedup off**
- ARC cap ~**4 GB** when HDD pool is busy (reserve RAM for VMs)
- `sync=standard` (no UPS)
- No HDD spindown for ZFS members

Detail: [`../../storage_server_setup.md`](../../storage_server_setup.md)

### ZFS / pool email alerts (Zoho SMTP)

Set up **2026-08-15** so RAIDZ1/`rpool` problems mail you (degraded pool, scrub errors, etc.) via Proxmox **Datacenter → Notifications**. This is separate from Scrutiny, which stays a dashboard/history UI only — its own alerting was never enabled. Temperature alerting is handled instead by [`configs/drive-temp-alert.sh`](configs/drive-temp-alert.sh) (see below).

| Item | Value |
|------|--------|
| Target name | `zoho-smtp` |
| SMTP server | **`smtp.zoho.eu`** (not `smtppro` — free/custom-domain mailbox) |
| Encryption / port | TLS / **465** |
| Auth user / From | `zfs.notification@dustinwalker.de` |
| Password | Zoho mailbox password or **App Password** (if 2FA) — not in git |
| Additional recipient | `mail@dustinwalker.de` |
| Matcher | `default-matcher`, `mode all` -> target **`zoho-smtp`**. The `mail-to-root` *endpoint* exists but is **not** a matcher target |

**DNS on host (required for SMTP):** resolvers must reach Zoho. Under `vmbr0`:

```text
dns-nameservers 192.168.1.1 1.1.1.1
dns-search local
```

If Test fails with “Temporary failure in name resolution”, fix `/etc/resolv.conf` / those lines first.

**Verify:** Datacenter → Notifications → `zoho-smtp` → **Test** → mail arrives at `mail@dustinwalker.de`.

**Domain email records** (verified 2026-08-18, authoritative DNS at Netlify) — shared by Proxmox alerts and Seafile:

| Record | Value / state |
|--------|----------------|
| MX | `mx.zoho.eu` (10), `mx2` (20), `mx3` (50) |
| SPF | `v=spf1 include:zoho.eu ~all` — matches the EU DC / `smtp.zoho.eu` |
| DKIM | present under selector **`zmail`** (not `zoho`), 1024-bit |
| DMARC | **absent** — optional; `p=none` would add visibility |
| Alias | `cloud@dustinwalker.de` on the `zfs.notification` mailbox (Seafile sender; **not** set as mailbox address) |

### Drive temperature alert

Set up **2026-08-22**. Script [`configs/drive-temp-alert.sh`](configs/drive-temp-alert.sh)
-> `/usr/local/sbin/`, schedule [`configs/cron.d-drive-temp-alert`](configs/cron.d-drive-temp-alert)
-> `/etc/cron.d/`. Every 20 minutes. Shares `/etc/zfs-capacity-alert.cred` so there is no
second copy of the password.

**Covers temperature only.** Reallocated/pending sector growth and failed self-tests are still
unalerted -- see the notifications table.

| Drive | Dev | Type | Idle | Peak recorded |
|-------|-----|------|------|---------------|
| ST2000DM001-1ER164 `Z4Z2CNQR` | `sda` | HDD | 36 | **43** |
| Samsung SSD 860 EVO 500GB | `sdb` | SSD | 28 | – |
| Crucial CT120BX500SSD1 | `sdc` | SSD | 32 | 41 |
| Samsung SSD 850 EVO 250GB | `sdd` | SSD | 29 | – |
| ST2000NM012A `WS109WW8` | `sde` | HDD | 39 | **47** |
| ST2000NM012A `WS10P9G6` | `sdf` | HDD | 35 | 42 |

Thresholds live at the top of the script: `TEMP_MAX_HDD` / `TEMP_MAX_SSD`, plus an optional
per-**serial** override map. Keyed on serial and not `/dev/sdX` because device letters can move
between reboots. **Both are set to 40 temporarily for validation**; sensible long-term values
are HDD 45 / SSD 50 (`sde` idles at 39, so 40 will trip under any real load -- which is the
point of the temporary setting).

Non-obvious things this script has to handle:

- **Temperature lives under two different SMART attributes here.** `194 Temperature_Celsius` on
  the Crucial and both Seagates; `190 Airflow_Temperature_Cel` on both Samsungs. The Seagates
  report both. A script checking only one attribute silently reports nothing for half the disks.
  Field 10 is the raw value in either case.
- **`smartctl` exits non-zero on healthy drives.** It returns a bitmask, and bit 6 ("an
  attribute is in its old-age range") is set on every drive here. Every call needs `|| true`, or
  `set -e` kills the script on a perfectly good disk.
- **`-n standby`** so a sleeping disk is never spun up just to read a temperature. Irrelevant
  today (no spindown on ZFS members) but free insurance.
- **Mail is `text/html` with inline styles only.** Plain-text columns were tried first and were
  unreadable -- mail clients render in a proportional font, so fixed-width alignment collapses.
  No `<style>` block, no external CSS, no images: clients strip all three.

Rate limiting: mails when the **set** of over-limit drives changes (so a second drive going hot
escalates at once rather than being swallowed by a reminder window), then every 6 h while it
persists, then once on recovery. State in `/var/lib/drive-temp-alert/state`.

```bash
/usr/local/sbin/drive-temp-alert.sh --test    # always mails, ignores thresholds
/usr/local/sbin/drive-temp-alert.sh; echo "exit=$?"   # exit 1 = something is over limit
journalctl -t drive-temp-alert --since today
```

**Deliberately not sharing Scrutiny's collector schedule** (which is a systemd timer, not cron).
One job hanging off another's schedule means a failure in either kills both, and a change to the
collector's timer would silently change this alert. Reading Scrutiny's API would also make the alert depend on LXC 102 being up to tell
you a disk is overheating. SMART attribute reads are cheap, so polling twice costs nothing.

### ZED -> email: the `mail-to-root` path is separate, and it was silently broken

**Verified working 2026-08-22.** Two *different* mail paths exist on this host and they fail
independently -- this cost days of false confidence:

| Path | Used by | Transport |
|------|---------|-----------|
| Notification target direct | Datacenter -> Notifications **Test**, Proxmox backup jobs | PVE's own SMTP client -> Zoho |
| **mail-to-root** | **ZED** (pool degraded, scrub/checksum errors), cron, smartd | `mail` -> postfix -> `/root/.forward` -> `/usr/libexec/proxmox-mail-forward` -> notification system -> Zoho |

**A passing `zoho-smtp` Test says nothing about whether ZED can reach you.**

The break: **`/etc/aliases.db` did not exist**, so postfix refused to resolve `root` and
deferred every message with `status=deferred (alias database unavailable)`. Silent -- mail piles
up in the queue instead of erroring anywhere visible. A real scrub notification from
2026-08-18 22:40 sat undelivered for **3.7 days** until the fix.

```bash
newaliases            # compiles /etc/aliases -> /etc/aliases.db; idempotent
postqueue -f          # retry deferred mail
mailq                 # must be empty
```

Health check (all three must hold):

```bash
ls -l /etc/aliases.db                        # must exist
ls -l /usr/libexec/proxmox-mail-forward      # note: NOT /usr/libexec/proxmox/...
mailq                                        # "Mail queue is empty"
```

**`ZED_NOTIFY_VERBOSE=1`** is set in `/etc/zfs/zed.d/zed.rc` on purpose (backup at
`/root/zed.rc.bak-2026-08-18`). Default is off, which mails only on *errors* -- so a clean
weekly scrub would send nothing and silence would be ambiguous. With it on, the Sunday scrub
emails every week and becomes a **heartbeat for the whole alert chain**: as long as it keeps
arriving, ZED, postfix, the forwarder, the matcher and Zoho are all alive.

Note `zinject` is **not** shipped by Proxmox's `zfsutils-linux`, so faults cannot be simulated
that way. A scrub with verbose notifications on is the zero-risk substitute -- no need to
unplug a disk.

### Local ZFS snapshots (sanoid)

Set up **2026-08-18**. Package `sanoid` 2.2.0 from trixie/main; config committed at
[`configs/sanoid.conf`](configs/sanoid.conf) → `/etc/sanoid/sanoid.conf`.
The Debian package ships **no** default config — without the file sanoid aborts with
`cannot load /etc/sanoid/sanoid.conf`.

| Dataset | Retention |
|---------|-----------|
| `tank/vm-101-disk-0` (Seafile blocks + SQL dumps) | 12 hourly, 7 daily, 2 weekly |
| `rpool/data/vm-101-disk-1` (VM 101 OS + live MariaDB) | 7 daily |

`daily_hour = 4` is deliberate: the guest dumps its databases at 03:15, so each daily
snapshot contains block store **and** a fresh SQL dump = one consistent restore set.

Snapshots protect against deleted libraries / bad `rm` / ransomware / failed upgrades.
They do **not** protect against pool or site loss — Kopia offsite is still required.
`autoprune` only touches sanoid's own `autosnap_*` names; `qm snapshot` snapshots are safe.

```bash
systemctl list-timers sanoid.timer
zfs list -t snapshot
zfs list -o name,used,avail,refer,usedbysnapshots tank tank/vm-101-disk-0
```

**Stale VM snapshots are a hazard once real data exists** — `before-ocis-full-server` and
`before-seafile-cutover` predated Seafile, so rolling back would have destroyed live data
while protecting nothing. Both deleted 2026-08-18; the cutover one alone was pinning **179G**.

### Space accounting gotcha (thick zvol on RAIDZ)

`tank/vm-101-disk-0` was created **thick** (`refreservation` ≈ 2.98T of ~3.53T usable), so
pool `AVAIL` is mostly reservation, not free space. Counter-intuitive consequence: **freeing
data inside the guest lowers `AVAIL`**, because unwritten reserved space is charged at
worst-case RAIDZ parity inflation while written data costs less. Observed 2026-08-18:
`REFER` 571G→390G while `AVAIL` 377G→**166G**.

Snapshots are not the problem (`USEDSNAP` was 714K). If snapshot headroom gets tight, the
lever is the reservation:

```bash
zfs set refreservation=none tank/vm-101-disk-0   # thin; reversible
```

Trade-off: removes the guarantee that the guest can always write its full 2.93T, so pool
capacity must be monitored. Also tick **Thin provision** on the `tank` storage in
Datacenter → Storage so future disks are sparse.

### Pool capacity alert (cron + curl -> Zoho)

Set up **2026-08-18**. Script [`configs/zfs-capacity-alert.sh`](configs/zfs-capacity-alert.sh)
-> `/usr/local/sbin/`, schedule [`configs/cron.d-zfs-capacity-alert`](configs/cron.d-zfs-capacity-alert)
-> `/etc/cron.d/`. Runs hourly at :25.

**Why a script and not a Proxmox notification:** ZED and Datacenter -> Notifications cover pool
*health* (degraded vdev, scrub/checksum errors). Neither emits any event for a pool that is
merely **filling up**, and Proxmox's notification targets cannot be invoked from a script with
an arbitrary message.

**Why `curl` and not `mail -s ... root`:** postfix *is* installed on this host (corrected
2026-08-18 -- earlier notes here wrongly said "no local MTA"), so the mail-to-root path is
available and would avoid a second copy of the SMTP password. It is deliberately **not** used:
that path depends on postfix + `/root/.forward` + `proxmox-mail-forward` + pmxcfs, and a
capacity warning should not share a single point of failure with every other alert. Cost of the
choice is the duplicated credential, tracked in the rotation to-do in `../../memory.md`.

Two independent triggers, because on this host the two numbers disagree:

| Trigger | Threshold | What it catches |
|---------|-----------|-----------------|
| `zpool list` allocation | >= **85%** | Genuine fill-up + the ~80% fragmentation cliff. Counts allocated blocks only, so it **ignores reservations** -- `tank` reads ~11% |
| Root dataset `AVAIL` | `tank` < **40G**, `rpool` < **30G** | Snapshot headroom. Accounts for `refreservation`, so tank's ~166G AVAIL *is* all the room the thick zvol leaves for snapshot divergence |

Mails on entry into alert, again every 24 h while it persists, and once on recovery.
State in `/var/lib/zfs-capacity-alert/<pool>`; delete a file to re-arm.

Credentials in **`/etc/zfs-capacity-alert.cred`** (mode `600`, curl config format, **not in git**);
passed with `--config` rather than `--user` so the password never appears in `ps`.

```bash
/usr/local/sbin/zfs-capacity-alert.sh --test    # always mails, ignores thresholds
/usr/local/sbin/zfs-capacity-alert.sh; echo "exit=$?"   # exit 1 = a pool is in alert
journalctl -t zfs-capacity-alert --since today
```

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
| 101 | `seafile` (renamed from `ocis` 2026-08-18) | File cloud — Seafile 13 CE | Live — [`../seafile/`](../seafile/) |
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
