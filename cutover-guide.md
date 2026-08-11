# Phase 1 cutover guide — Proxmox bridges → OPNsense → Smart 3 modem

> **Superseded for Stage 5+:** Use [`opnsense-rebuild-guide.md`](opnsense-rebuild-guide.md) and [`memory.md`](memory.md) for the proven double-NAT → modem procedure (2026-08). Keep this file for Stage 0–4 history and dual-cable bridge moves.

Follow in order. Do **not** skip verify steps.

**Progress:** Stages **0–4 + modem cutover complete** (see rebuild guide). This document’s Stage 5 is historical.

## Target (final)


| Bridge            | NIC              | Host IP           | Cable                           |
| ----------------- | ---------------- | ----------------- | ------------------------------- |
| `vmbr0` LAN       | `nic2` (I350)    | `192.168.1.10/24` | → house switch                  |
| `vmbr1` WAN       | `nic1` (I350)    | *none*            | → Smart 3 (modem)               |
| `vmbr2` emergency | `nic0` (Realtek) | `10.99.99.1/24`   | empty (laptop only when broken) |
| `vmbr3` DMZ       | *(none)*         | *none*            | Phase 2                         |



| Role                 | IP                                       |
| -------------------- | ---------------------------------------- |
| OPNsense LAN gateway | `192.168.1.1`                            |
| Proxmox management   | `192.168.1.10`                           |
| Emergency laptop     | `10.99.99.2` → `https://10.99.99.1:8006` |


**Sticker convention (lock this in):**


| Interface | Sticker                 |
| --------- | ----------------------- |
| `nic1`    | **WAN**                 |
| `nic2`    | **LAN**                 |
| `nic0`    | **EMERGENCY** (onboard) |


If your stickers differ, rewrite the table above before continuing — do not guess at the rack.

---



## Outage map (summary)


| Stage                         | Internet | Wi‑Fi                  | House LAN             | Proxmox UI                                    |
| ----------------------------- | -------- | ---------------------- | --------------------- | --------------------------------------------- |
| 0–2 prep / VM install         | up       | up                     | up                    | up (done)                                     |
| 3 dual-cable LAN move + Apply | up       | up                     | up                    | laptop on house Ethernet; emergency as backup |
| 4 OPNsense install/config     | up       | up                     | up                    | up                                            |
| 5 modem cutover               | **DOWN** | **DOWN***              | **DOWN** then new LAN | laptop on Ethernet (switch or emergency)      |
| 6 after success               | up       | **only if AP on LAN*** | up (`192.168.1.0/24`) | `https://192.168.1.10:8006`                   |


Smart 3 in modem mode usually **kills its Wi‑Fi**. You need a separate AP on the LAN after cutover, or accept no Wi‑Fi until then.

---



## Workstation for Stage 3+ (laptop + Ethernet)

You finished Stages 0–2 on the gaming PC (Wi‑Fi). From **Stage 3 onward**, work from the **laptop at the server** with an Ethernet cable. Do **not** rely on Wi‑Fi for Proxmox Apply / cutover.


| Role                        | Device / setup                                                                |
| --------------------------- | ----------------------------------------------------------------------------- |
| Drive Proxmox UI + OPNsense | **Laptop**, Ethernet to house switch (same `192.168.2.0/24` as Proxmox today) |
| Cable swaps                 | You are at the rack — same session                                            |
| Break-glass                 | Same laptop → Realtek (`nic0` / `vmbr2`) with static `10.99.99.2`             |


**Why Ethernet to the switch (not Wi‑Fi):** Apply on bridges can briefly disrupt L2; a wired path on the house LAN is far more reliable than Wi‑Fi while you move `vmbr0` from Realtek → I350 LAN.

**Laptop house-LAN settings (Stage 3–4, before cutover):** DHCP from Smart 3 is fine (`192.168.2.x`). Browser: `https://192.168.2.10:8006`.

**Emergency laptop network (Windows) — only when plugged into Realtek:**

- IP `10.99.99.2`
- Mask `255.255.255.0`
- Gateway empty
- Browser `https://10.99.99.1:8006`

After emergency test, set the adapter back to DHCP (or your normal profile) before continuing on the switch.

---



## Before you start (checklist)

- [x] OPNsense ISO uploaded to Proxmox
- [x] Telekom Zugangsdaten written down (Anschlusskennung, Zugangsnummer, Kennwort)
- [x] Stickers: `nic1=WAN`, `nic2=LAN` (or document your mapping)
- [x] Stages 0–2 done (`vmbr1`/`vmbr2`/`vmbr3` exist; UI still `https://192.168.2.10:8006`)
- [x] Laptop + Ethernet cable (you are on this machine now)
- [x] Spare evening (60–90 min for modem cutover)
- [x] Wi‑Fi plan after cutover: spare AP **or** accept downtime
- [x] Rollback: Speedport 7 or Smart 3 back to full router (don’t factory‑reset the working Smart 3 config until OPNsense is proven)

---



## Stage 0 — Snapshot of current network (5 min)

On Proxmox shell:

```bash
cp /etc/network/interfaces /root/interfaces.bak-$(date +%F)
cat /etc/network/interfaces
ip -br a
```

- [x] Backup saved  
- [x] Confirm `vmbr0` uses `nic0`, IP `192.168.2.10/24`, gateway `192.168.2.1`

---



## Stage 1 — Create OPNsense VM (house stays online)

**Create VM**


| Field              | Value                                                                    |
| ------------------ | ------------------------------------------------------------------------ |
| VM ID              | `100`                                                                    |
| Name               | `opnsense`                                                               |
| ISO                | OPNsense DVD ISO                                                         |
| Guest OS           | Other                                                                    |
| Machine            | `q35`                                                                    |
| BIOS               | SeaBIOS                                                                  |
| SCSI controller    | VirtIO SCSI single                                                       |
| Disk               | `local-zfs`, **20 GB**, SCSI, discard on                                 |
| CPU                | 2 cores, type `host`                                                     |
| CPU units          | `4096` (Advanced)                                                        |
| Memory             | `2048` MB, ballooning off                                                |
| NIC net0           | bridge `vmbr0`, VirtIO, firewall off *(temporary; we rebind in Stage 4)* |
| Start after create | **No**                                                                   |


Add second NIC now or in Stage 4:

- net1 → will be LAN on `vmbr0` finally; for install you can leave only net0 until bridges exist

**Simpler:** create VM with **no** start; finish bridges (Stage 3); then set:

- net0 → `vmbr1` (WAN)
- net1 → `vmbr0` (LAN)

Then install.

- [x] VM created, not started (or stopped)
- [x] ISO attached

---



## Stage 2 — Pre-create empty bridges (still online)

**pve → System → Network**

### 2a. Create `vmbr1` (WAN)


| Field        | Value       |
| ------------ | ----------- |
| Name         | `vmbr1`     |
| Bridge ports | `nic1`      |
| IPv4         | *empty*     |
| Gateway      | *empty*     |
| Autostart    | yes         |
| Comment      | WAN → modem |




### 2b. Create `vmbr2` (emergency) — not yet enslaving `nic0`

Create bridge **without** taking `nic0` from `vmbr0` yet:


| Field        | Value           |
| ------------ | --------------- |
| Name         | `vmbr2`         |
| Bridge ports | *empty for now* |
| IPv4/CIDR    | `10.99.99.1/24` |
| Gateway      | *empty*         |
| Autostart    | yes             |
| Comment      | emergency       |




### 2c. Create `vmbr3` (DMZ, Phase 2)


| Field        | Value       |
| ------------ | ----------- |
| Name         | `vmbr3`     |
| Bridge ports | *empty*     |
| IPv4         | *empty*     |
| Autostart    | yes         |
| Comment      | DMZ Phase 2 |


Click **Apply Configuration**.

- [x] `vmbr1`, `vmbr2`, `vmbr3` exist  
- [x] UI still on `https://192.168.2.10:8006`  
- [x] House internet still up  

---



## Stage 3 — Move LAN + emergency (risk window)

**Status:** Stages 0–2 are done. You are on the **laptop** with Ethernet.

**Goal while Smart 3 still routes** `192.168.2.0/24`**:**

- `vmbr0`: ports = `nic2` only, keep IP `192.168.2.10/24`, gw `192.168.2.1`
- `vmbr2`: ports = `nic0`, IP `10.99.99.1/24`
- Physical: house uplink ends on I350 **LAN (**`nic2`**)**; Realtek **empty** (emergency)

**Why not “unplug Realtek, then Apply”?**  
After you unplug Realtek, `https://192.168.2.10:8006` dies before you can Apply. Use the **dual-cable** sequence below instead.

**Setup before you touch bridges:**

1. Plug laptop Ethernet into the **house switch** (or Smart 3 LAN) — same L2 as Proxmox today.
2. Confirm DHCP IP in `192.168.2.0/24` and open `https://192.168.2.10:8006`.
3. Keep this browser tab ready; do cable work at the rack without relying on Wi‑Fi.



### 3a. Dual-cable prepare (at the server)

1. Leave the existing cable in **Realtek (**`nic0`**)** plugged into the switch/Smart 3 LAN.
2. Plug a **second** cable: same switch/Smart 3 LAN → sticker **LAN (**`nic2`**)**.
3. Both `nic0` and `nic2` should have link to the house LAN for a short time.
4. Laptop stays on the switch (its own cable). Do **not** steal the Realtek cable for the laptop yet.



### 3b. Edit bridges in UI (laptop on house Ethernet)

1. Edit `vmbr0`: Bridge ports = `nic2` only (remove `nic0`). Keep `192.168.2.10/24` and gateway `192.168.2.1`.
2. Edit `vmbr2`: Bridge ports = `nic0`. Keep `10.99.99.1/24`.
3. **Apply Configuration** now (both physical ports still cabled).
4. Confirm UI still works from the laptop: `https://192.168.2.10:8006`



### 3c. Remove Realtek from the house LAN

1. At the server: **unplug** the cable from **Realtek (**`nic0`**)**. Leave Realtek empty.
2. Keep the cable on **LAN (**`nic2`**)**.
3. Confirm UI still works from the laptop on the switch.

**Emergency test (recommended — same laptop, one cable move):**

1. Note: you will briefly lose house-LAN access on the laptop.
2. Unplug laptop from the switch → plug into **Realtek (**`nic0`**)**.
3. Set Windows adapter to static `10.99.99.2` / `255.255.255.0` / no gateway.
4. Open `https://10.99.99.1:8006` — confirm Proxmox UI.
5. Unplug from Realtek → plug laptop back into the **switch**.
6. Set adapter back to **DHCP**. Confirm `https://192.168.2.10:8006` again.

**If UI dead after Apply:**

1. Laptop → Realtek with static `10.99.99.2/24`
2. `https://10.99.99.1:8006`
3. Fix `/etc/network/interfaces` or restore `/root/interfaces.bak-*`
4. `ifreload -a` (or reboot)



### 3d. Verify

On Proxmox shell (UI → Shell, or SSH from laptop):

```bash
ip -br a
bridge link
cat /etc/network/interfaces
```

Expect:

- `vmbr0` UP, `192.168.2.10`, slave `nic2`  
- `vmbr1` exists, slave `nic1`, no IP  
- `vmbr2` has `10.99.99.1`, slave `nic0`  
- `nic0` has no house cable  

- [ ] Proxmox UI via `192.168.2.10` from laptop on switch  
- [ ] Internet on laptop still works (Smart 3)  
- [ ] Emergency port tested once (recommended)

---



## Stage 4 — OPNsense NICs + install (house still online)

Laptop stays on house Ethernet → switch → `https://192.168.2.10:8006`.

### 4a. Attach NICs

VM **opnsense** → Hardware:


| net  | Bridge        | Model  |
| ---- | ------------- | ------ |
| net0 | `vmbr1` (WAN) | VirtIO |
| net1 | `vmbr0` (LAN) | VirtIO |


WAN cable to modem stays **unplugged** until Stage 5 (or plugged but unused).

### 4b. Install

1. Start VM → Console (from laptop browser)
2. Install OPNsense to disk (UFS OK)
3. Set root password
4. Remove ISO from Hardware, reboot



### 4c. Assign interfaces (console)


| OPNsense | vtnet    | Bridge  |
| -------- | -------- | ------- |
| WAN      | `vtnet0` | `vmbr1` |
| LAN      | `vtnet1` | `vmbr0` |


Set LAN to `192.168.1.1/24` already (even though house is still `.2` — OK; you’re not serving DHCP to the house yet).

**Do not** enable LAN DHCP for the whole house until Stage 5.

WAN: leave DHCP for now (will be idle/no carrier) or set PPPoE ready but not connected.

### 4d. Reach OPNsense GUI before cutover

Proxmox still has `192.168.2.10` on `vmbr0`. OPNsense LAN is `192.168.1.1` on same bridge → both IPs on one L2 segment is OK temporarily.

From Proxmox shell:

```bash
ping -c2 192.168.1.1
```

**Option A — SSH tunnel (simple, keeps laptop on DHCP** `.2`**):**

```powershell
ssh -L 8443:192.168.1.1:443 root@192.168.2.10
```

Browser: `https://127.0.0.1:8443`  
Login: `root` / your password  

**Option B — secondary IP on the laptop Ethernet adapter (no tunnel):**

Keep DHCP for `192.168.2.x`, then add a second address:

```powershell
# Replace "Ethernet" with your adapter name from Get-NetAdapter
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 192.168.1.2 -PrefixLength 24
```

Browser: `https://192.168.1.1`  
Remove later with `Remove-NetIPAddress` (or reboot) when done.

In OPNsense: update, set hostname, **disable LAN DHCP** until cutover (or restrict), install HAProxy later — not now.

- [ ] OPNsense installed  
- [ ] GUI reachable (tunnel or secondary IP)  
- [ ] LAN `192.168.1.1`, DHCP off for house  

---



## Stage 5 — Modem cutover (planned outage)

**Everyone offline for this stage.** Work only from the **laptop on Ethernet**.

Before you start the outage window:

- Laptop Ethernet → **house switch** (not Wi‑Fi).
- Bookmark `https://192.168.2.10:8006` (old) and prepare for `https://192.168.1.10:8006` / `https://192.168.1.1`.
- Know the emergency fallback: laptop → Realtek, static `10.99.99.2` → `https://10.99.99.1:8006`.



### 5a. Final OPNsense prep (still on old internet)

In OPNsense GUI (tunnel or secondary IP from Stage 4):

1. **System → Firmware** updated
2. WAN: prepare **PPPoE** with Telekom credentials
  - Username often: `Anschlusskennung#Zugangsnummer@t-online.de` (confirm Telekom format for your contract)  
  - Password: persönliches Kennwort  
  - If no sync: try VLAN **7** on WAN (Telekom VDSL classic) — only if needed
3. LAN: `192.168.1.1/24`
4. **Enable DHCP** on LAN: range e.g. `192.168.1.100–200`, gateway `192.168.1.1`, DNS `192.168.1.1` or `1.1.1.1`
5. Firewall: WAN block inbound default; LAN allow



### 5b. Change Proxmox management IP (same outage window)

**Before** or **right as** you cut modem — Proxmox must land on the new subnet:

Edit `vmbr0`:


| Field     | Value             |
| --------- | ----------------- |
| IPv4/CIDR | `192.168.1.10/24` |
| Gateway   | `192.168.1.1`     |


Apply when OPNsense is running and will be the gateway (or you will use emergency access).

**Laptop tip:** After this Apply, your laptop’s DHCP `.2` address may no longer reach Proxmox until OPNsense DHCP is live. If the UI drops:

1. Prefer: wait until Stage 5c–5d and renew DHCP (`ipconfig /renew`) once OPNsense is gateway.
2. Or: emergency port → fix / finish Apply.
3. Or: set laptop static `192.168.1.2/24`, gateway `192.168.1.1`, then open `https://192.168.1.10:8006`.



### 5c. Physical modem cutover

1. Smart 3 UI → set **Exklusiver Modem-Modus** / modem mode (wording varies).
2. Wait for modem sync.
3. Cable: **Smart 3 LAN/modem out → Proxmox WAN sticker (**`nic1` **/** `vmbr1`**)**.
4. House switch stays on **LAN sticker (**`nic2`**)**.
5. Start/confirm OPNsense running; WAN PPPoE **up** (dashboard).



### 5d. Verify

From laptop on switch (DHCP renew if needed — expect `192.168.1.x`):

- [ ] IP in `192.168.1.0/24`  
- [ ] Ping `192.168.1.1` (OPNsense)  
- [ ] Ping `192.168.1.10` (Proxmox)  
- [ ] Browse internet  
- [ ] `https://192.168.1.10:8006`  
- [ ] `https://192.168.1.1` (OPNsense)

Speedtest roughly ~50/20 class.

### 5e. Rollback if WAN fails

1. Smart 3 back to **full router**
2. Modem cable back to old layout; Proxmox LAN cable to Smart 3 LAN/switch as before Stage 5
3. Temporarily set Proxmox `vmbr0` back to `192.168.2.10/24` gw `192.168.2.1` if needed (emergency port if UI unreachable)
4. Laptop back to DHCP on switch; house works again; debug OPNsense PPPoE later

---



## Stage 6 — Stabilize

Laptop on house Ethernet (`192.168.1.0/24` via DHCP):

- [ ] OPNsense: backup config (System → Configuration → Backups)  
- [ ] Proxmox: confirm `vmbr1` still has **no** IP  
- [ ] Emergency port still empty; retest once from laptop  
- [ ] Wi‑Fi: plug AP into switch, or document “no Wi‑Fi until AP”  
- [ ] Update `memory.md` with new IPs and sticker labels  
- [ ] Leave Speedport 7 / Smart 3 rollback path documented  

**Not yet:** DMZ VMs, HAProxy/SNI, Seafile, Dockploy.

---



## Quick reference — cables after success

```text
[TAE/DSL] -- [Smart 3 MODEM] --WAN-- [nic1 vmbr1] -- OPNsense
                                         |
[House PCs/AP/switch] ----------LAN-- [nic2 vmbr0] -- OPNsense + Proxmox .10
                                         |
[Laptop only when broken] ---- [nic0 vmbr2 10.99.99.1]
```

