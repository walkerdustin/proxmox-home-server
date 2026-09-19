# Homelab memory

Working notes for the Proxmox home-server build. Update as hardware/network facts change.

**Last verified:** 2026-08-17 — DMZ up; **Seafile 13 CE** public at `https://cloud.dustinwalker.de` (HAProxy → Caddy). oCIS was replaced on the same VM 2026-08-17; the ingress model survived unchanged. Component docs: [`homelab-components/`](homelab-components/).

## Current production topology

```text
[TAE/DSL] -- [Smart 3 MODEM LAN4] --WAN-- [nic1 / vmbr1]
                                              |
                                    OPNsense: VLAN7 → PPPoE → WAN
                                              |
                              OPNsense LAN 192.168.1.1 (vtnet1 / vmbr0)
                                              |
[House / UniFi AP / PoE switch] ----LAN-- [nic2 / vmbr0] -- Proxmox 192.168.1.10
                                              |
[Laptop only when broken] ---------- [nic0 / vmbr2 10.99.99.1]
```

| Item | Value |
|------|--------|
| Edge | Telekom Speedport Smart 3 in **DSL modem mode** |
| Modem cable | Smart 3 **LAN 4** → Proxmox `nic1` (WAN sticker) |
| Modem status UI | `http://169.254.2.1` from Smart 3 LAN 1–3 only (read-only) |
| House LAN subnet | `192.168.1.0/24` |
| OPNsense LAN | `192.168.1.1/24` (DHCP server on) |
| DHCP pool | `192.168.1.100`–`192.168.1.200` |
| LAN DNS | Unbound on `192.168.1.1`, **forwarding** to `1.1.1.3` / `1.0.0.3` (Cloudflare malware + adult filter) with **Forward first** |
| Static IP bands | `.1`–`.29` infra · `.30`–`.59` IoT reservations · `.100`–`.200` DHCP pool |
| Proxmox management | `https://192.168.1.10:8006` |
| OPNsense GUI | `https://192.168.1.1:8443` (LAN only; port moved for HAProxy) |
| Wi‑Fi | UniFi U7 on PoE switch behind OPNsense (Smart 3 Wi‑Fi off) |
| Proxmox hostname | `pve` |
| Proxmox version | VE 8.2.x (no-subscription repo); kernel `7.0.14-*-pve` |
| Host RAM | **32 GB** DDR4 (4×8 GB mixed: 2× Kingston KHX2666 + 2× Corsair 2133); running **JEDEC 2133 MT/s** |
| Host CPU | Intel Core i5-6600K (4c/4t) |
| OPNsense version | 26.7.x in VM 100 (`opnsense`), **Start at boot = Yes**, RAM **3072 MB** |

### OPNsense WAN stack (critical)

| Layer | Device | Notes |
|-------|--------|--------|
| Physical / VirtIO | `vtnet0` → Proxmox `vmbr1` / `nic1` | No host IP on `vmbr1` |
| VLAN | `vlan01` tag **7** parent `vtnet0` | Must **Apply** after create or it may not exist at runtime |
| PPPoE | `pppoe0` on `vlan01` | Telekom username format `Anschlusskennung#Zugangsnummer@t-online.de` |
| Assigned WAN | `pppoe0` | Block private + bogon **on**; IPv6 None for now |

LAN: `vtnet1` → `vmbr0` / `nic2`.

## Host NICs (pve)

| Name | Altname | MAC | PCI | Role |
|------|---------|-----|-----|------|
| `nic0` | `enx4ccc6a6de0ed` | `4c:cc:6a:6d:e0:ed` | `0000:03:00.0` | EMERGENCY → `vmbr2` `10.99.99.1/24` (cable empty) |
| `nic1` | `enx98b78524968a` | `98:b7:85:24:96:8a` | `0000:01:00.0` | WAN → `vmbr1` (no Proxmox IP) |
| `nic2` | `enx98b78524968b` | `98:b7:85:24:96:8b` | `0000:01:00.1` | LAN → `vmbr0` `192.168.1.10/24` gw `192.168.1.1` |

| Sticker | Interface |
|---------|-----------|
| **WAN** | `nic1` |
| **LAN** | `nic2` |
| **EMERGENCY** | `nic0` |

| Bridge | Port | Host IP |
|--------|------|---------|
| `vmbr0` | `nic2` | `192.168.1.10/24`, gateway `192.168.1.1` |
| `vmbr1` | `nic1` | none |
| `vmbr2` | `nic0` | `10.99.99.1/24` |
| `vmbr3` | none | DMZ — OPNsense `vtnet2` `10.10.10.1/24`; Seafile VM 101 `10.10.10.10` |

## Storage

| Item | Detail |
|------|--------|
| `rpool` | ZFS mirror |
| Disk A | Samsung 850 EVO 250GB — `S2CJNXAG514758J` (`…-part3`) |
| Disk B | Samsung 860 EVO 500GB — `S3Z2NB0KA29651E` (`…-part3`) |
| ESPs | `A0B2-D849` (250GB), `041E-0F11` (500GB) |
| `tank` | RAIDZ1 HDDs — Seafile data VDisk (`vm-101` scsi1 ~3 TB), guest `/mnt/data` |
| Seafile layout | blocks + SQL dumps on `tank`; **live MariaDB on the SSD OS disk** (`/opt/seafile-mysql/db`) for commit latency |
| Other | ~120GB Crucial — planned local backup target later |

## Recovery notes (learned the hard way)

- Prefer an **admin-capable** PC for temporary static IPs during migrations; locked corporate laptops cannot set static IPs.
- Idle I350 ports may show `DOWN` until `ip link set nicX up` (admin up) before link lights appear.
- Overlapping addresses during LAN move: Proxmox temporary `192.168.1.10` while still on `.2.10`; admin PC both `.2.x` and `.1.x`.
- Isolate the downstream PoE switch **before** enabling OPNsense DHCP so two DHCP servers never share L2.
- Smart 3 modem rollback requires **factory reset + restore** of saved config (not a simple toggle).
- OPNsense XML backups contain secrets — keep them private; do not commit.

## Guides

| File | Role |
|------|------|
| [`homelab-components/`](homelab-components/) | As-built docs per component (OPNsense, oCIS, Proxmox, …) |
| [`opnsense-rebuild-guide.md`](opnsense-rebuild-guide.md) | **Authoritative** rebuild / cutover from scratch (double NAT → modem) |
| [`cutover-guide.md`](cutover-guide.md) | Historical Stage 0–4 notes; Stage 5 superseded |

## Phase status

- [x] BIOS power/virt settings (MSI Z170-A PRO)
- [x] Proxmox install + no-subscription updates
- [x] `rpool` mirror + both ESPs bootable
- [x] Bridges `vmbr0`–`vmbr3`; LAN on `nic2`; emergency on `nic0`
- [x] OPNsense VM installed (UFS), dual NIC, PPPoE + VLAN 7
- [x] UniFi U7 behind OPNsense; Smart 3 Wi‑Fi off
- [x] Smart 3 modem mode + OPNsense as edge router
- [x] Host RAM 32 GB installed (Phase 1 hardware complete)
- [x] DMZ + HAProxy SNI + oCIS public (`cloud.dustinwalker.de`); Tika on, Collabora off; Tika search smoke-tested
- [x] **oCIS → Seafile 13 CE** on VM 101 (2026-08-17): Caddy replaced Traefik, production LE first try, nightly SQL dumps armed. Ingress, DNS and HAProxy untouched. Accepted loss: **no full-text content search** (CE limitation). Record: [`homelab-components/seafile/cutover-from-ocis.md`](homelab-components/seafile/cutover-from-ocis.md)

### Open to-do (post–Seafile cutover)

Detail + order: [`homelab-components/seafile/README.md`](homelab-components/seafile/README.md) §7.

- [x] Seafile upload/download verified in bulk (~500 GB uploaded by 2026-08-18)
- [x] Reboot test on VM 101 passed 2026-08-18 (route clean, `/mnt/data` mounted, containers + certs returned)
- [x] VM 101 renamed `ocis` → `seafile` (2026-08-18); ext4 label stays `ocis-data` (historical)
- [x] `docker.service` drop-in `RequiresMountsFor=/mnt/data` — blocks containers initializing into an unmounted bind path (`nofail` in fstab would otherwise boot silently without tank)
- [x] **Seafile users locked 2026-09-17** — self-registration off; friend accounts exist; per-user quota 500 GB in the Users table (Phillip 1 TB on purpose). No `[quota] default` in `seafile.conf`; new accounts are set by hand when created
- [x] **DMZ firewall hardened 2026-08-18** — 8 ordered rules on the DMZ interface; DNS restricted to `DMZ address` only (so OPNsense sees every lookup the DMZ makes), `DMZ → LAN net` and `DMZ → This Firewall` blocked **with logging**, egress limited to 53/123/80/443/465 + ICMP. TEMP allow-any **disabled, not deleted** — one-click revert. Rules: [`homelab-components/opnsense/README.md`](homelab-components/opnsense/README.md) §6
- [ ] Delete the disabled `TEMP allow DMZ outbound` rule once the hardened set has run ~a week (from 2026-08-18)
- [ ] When seeding Kopia over the LAN, add an explicit pass rule **above** the `DMZ → LAN` block, then remove it again
- [ ] Point clients at `https://cloud.dustinwalker.de` (Seafile clients; remove oCIS ones)
- [x] Seafile SMTP live 2026-08-18 via `seahub_settings.py` (Zoho EU 465 SSL, from `cloud@` alias) — no SMTP env vars exist; verified with Forgot-Password
- [ ] Fresh OPNsense XML backup (private)
- [ ] Kopia offsite → friend’s TrueNAS (`/mnt/data/seafile`: blocks **and** `backup-sql/`). **Postponed 2026-09-17** — friend has no capacity; data not treated as important enough for offsite right now. If resumed: `DMZ → LAN` is blocked, so a LAN-side seed needs a temporary pass rule above that block
- [ ] First restore drill on a disposable VM
- [ ] Local ZFS snapshots (sanoid) for the VM 101 data disk
- [x] Nightly Seafile SQL dumps (`seafile-backup-sql.timer`, 03:15, 14-day retention)
- [x] Scrutiny hub LXC 102 + host collector + **15‑min timer** (temps/history) — [`homelab-components/scrutiny/`](homelab-components/scrutiny/)
- [x] **Drive temperature alert 2026-08-22** — `/usr/local/sbin/drive-temp-alert.sh` + `/etc/cron.d/drive-temp-alert`, every 20 min, HTML email listing **all six** drives. Thresholds at **40 °C temporarily** for validation (long-term HDD 45 / SSD 50). Temperature lives under attribute **194** on the Crucial + Seagates but **190** on the Samsungs — checking only one silently misses half the disks. `smartctl` exits non-zero on healthy drives (bitmask), so every call needs `|| true`
- [x] **Seafile SQL dump alert 2026-09-17** — `/usr/local/sbin/seafile-sql-dump-alert.sh` + `/etc/cron.d/seafile-sql-dump-alert`, noon on `pve`. `qm guest exec` into VM 101; mails if today's dump dir is missing or the three `.sql` files are too small. Shares `/etc/zfs-capacity-alert.cred`. `--test` mailed. Docs: [`homelab-components/proxmox-host/README.md`](homelab-components/proxmox-host/README.md)
- [ ] **Remaining SMART gap** — nothing alerts on reallocated/pending sector growth or failed self-tests. Those predict failure better than temperature. Either extend `drive-temp-alert.sh` or wire up Scrutiny's shoutrrr
- [x] **LAN DNS filtering 2026-08-22** — Unbound switched from recursive to **forwarding** to `1.1.1.3`/`1.0.0.3` (Cloudflare malware + adult filter), *Forward first* on, prefetch on, caches `64m`/`128m`. Key trap: Unbound is recursive by default, so System → Settings → General DNS servers alone change **nothing** for clients — forwarding must be enabled explicitly, and "Use System Nameservers" no longer exists (explicit entries with empty `Domain` instead). Blocked + DNSSEC-signed names return **SERVFAIL** rather than `0.0.0.0`; both block. Cloudflare's `adult.testcategory.com` test domain is **stale** — it answered normally while filtering worked. Docs: [`homelab-components/opnsense/README.md`](homelab-components/opnsense/README.md) §3.1
- [ ] **DNS filter health check** — `Forward first` means Unbound silently falls back to *unfiltered* recursion if Cloudflare is unreachable, with no error anywhere. Build a cron on `pve` that resolves a known-blocked name via `192.168.1.1` and mails when the sentinel stops coming back (same shape as `drive-temp-alert.sh`, shared cred file)
- [x] **ESP32 desk light reservation 2026-08-22** — `esp32-6ADCB0` pinned to `192.168.1.30`. An Android *Automate* flow hits `http://<ip>/alarm` at alarm time for a sunrise fade, so a lease change breaks the morning alarm **silently**. Reservations are created from the `+` in the leases list (pre-fills MAC), and **must go into whichever of Kea / Dnsmasq is actually active** — the inactive one accepts the entry and does nothing
- [ ] **IoT VLAN** — two Shelly Gen3 plugs, the ESP32, a Tuya/Danfoss gateway and an Amazon device all sit on the trusted LAN alongside Proxmox management. Same shape of work as the DMZ (§6), and the `.30`–`.59` band already groups them
- [ ] Decide whether to add the LAN → `127.0.0.1:53` DNS redirect (Firewall → NAT → **Destination NAT**). Declined 2026-08-22 for simplicity — rationale, and the reason **not** to block port 853, are in [`homelab-components/opnsense/README.md`](homelab-components/opnsense/README.md) §3.2
- [ ] **DMARC** TXT for `dustinwalker.de` — start `v=DMARC1; p=none;` (SPF + DKIM selector `zmail` already live, verified 2026-08-18)
- [ ] **Zoho send quota is shared** — Seafile sends via the `cloud@` *alias* on `zfs.notification@`, so both draw on one per-user quota. A burst of share mails can starve **HDD/ZFS failure alerts**. Fix: give Seafile its own mailbox (Zoho limits are per-user), and/or raise `[SEAHUB EMAIL] interval`
- [ ] Tune Seafile digest `interval` in `seafevents.conf` (default `30m` → `4h`); no rate-limit option exists there
- [ ] DynDNS for Netlify `cloud` A record
- [x] **Pool capacity alert on `pve`** — done 2026-08-18. `/usr/local/sbin/zfs-capacity-alert.sh` + `/etc/cron.d/zfs-capacity-alert`, hourly at :25, curl → Zoho directly. Note: postfix **is** installed on `pve` (earlier notes said otherwise), so `mail -s .. root` → `proxmox-mail-forward` → PVE notifications would also work — curl is used on purpose so a capacity warning does not share a failure domain with every other alert. Two triggers, because `zpool list` and `zfs list` disagree by design here: allocation ≥ 85% **or** root-dataset `AVAIL` below floor (`tank` 40G, `rpool` 30G). Observed 2026-08-18: `tank` = 10% / 4.88T free per `zpool list` but only **166G** AVAIL per `zfs list` — a %-only alert would never fire. Docs: [`homelab-components/proxmox-host/README.md`](homelab-components/proxmox-host/README.md) §3
- [x] **Drive-health alert validated 2026-08-22** — and it was **broken**: `/etc/aliases.db` was missing, so postfix deferred all mail-to-root and **ZED notifications never arrived**, while the `zoho-smtp` target's **Test button passed the whole time** (different transport). Fixed with `newaliases` + `postqueue -f`; the Aug 18 scrub mail was delivered 3.7 days late. `ZED_NOTIFY_VERBOSE=1` now makes the weekly Sunday scrub a heartbeat for the entire chain. `zinject` is not shipped by Proxmox, so a scrub is the zero-risk test — no disk unplugging needed
- [x] First real scrub of the Seafile data 2026-08-18: **0 errors** on all three drives in 20 min (the Aug 16 scrub took 2s — it ran before the ~500 GB upload, so it verified nothing)
- [x] DMZ DNS fallback removed 2026-08-22 — `dns-nameservers 10.10.10.1` only, in `/etc/network/interfaces`; applied live via `/run/resolvconf/interface/ens18.inet` + `resolvconf -u` (never `ifdown ens18` — that drops the VM's only path)
- [ ] **Rotate Zoho SMTP to an app-specific password — one rotation, three consumers.** The same mailbox password is now in three places: Proxmox notifications (`/etc/pve/priv/notifications.cfg`), Seafile (`seahub_settings.py` on VM 101), and `/etc/zfs-capacity-alert.cred` on `pve`. It has also appeared in chat transcripts. Rotate all three together — piecemeal means one gets forgotten and alerts die silently
- [ ] Decide thick vs thin for `tank/vm-101-disk-0` (`refreservation`) once snapshot usage is non-trivial — see [`homelab-components/proxmox-host/README.md`](homelab-components/proxmox-host/README.md) §3
- [ ] **Restore drill** — rehearse SQL dump + snapshot restore on a throwaway VM; own docs call it non-negotiable
- [ ] ZFS ARC ~4 GB cap if needed under load
- [ ] Crucial SSD as local backup target
- [x] **Dockploy VM 103 live 2026-09-17** — Debian 13.7 on DMZ `10.10.10.20`, 4 vCPU / 8 GB / 40G, Dokploy v0.30.6 + Traefik 3.6.7. Panel is LAN-only at `http://10.10.10.20:3000` (`/register` until admin exists). Swarm advertise addr is the DMZ IP, not the WAN. HAProxy/DNS for public apps not wired yet. Docs: [`homelab-components/dockploy/`](homelab-components/dockploy/)
