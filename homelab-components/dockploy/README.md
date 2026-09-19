# Dockploy (Dokploy)

**Status:** Live (LAN panel)  
**Last verified:** 2026-09-17  
**Panel:** http://10.10.10.20:3000 (LAN / split-hairpin only; not on WAN)

Product is [Dokploy](https://dokploy.com) v0.30.6. This folder keeps the repo's original `dockploy` spelling.

Architecture: [`../../homeserver-plan.md`](../../homeserver-plan.md) §4–5 · Ingress: [`../../ocis-public-ingress-plan.md`](../../ocis-public-ingress-plan.md)

---

## 1. Role

DMZ Docker host for public web apps. Traefik terminates TLS on this VM. Separate from Seafile so app deploys do not share the file-cloud guest.

The panel is **not** published on the internet. Create the admin at the LAN URL above. Public hostnames are added later, one HAProxy SNI/Host pair at a time, the same way `cloud.dustinwalker.de` reaches Seafile.

---

## 2. Where it runs

| Item | Value |
|------|--------|
| Proxmox VM | **103** `dockploy` |
| OS | Debian 13.7 (trixie), `genericcloud` + cloud-init |
| vCPU / RAM | 4 / **8 GB** |
| OS disk | `scsi0` on `local-zfs` (40G, discard, iothread, ssd) |
| EFI | OVMF 4M, Microsoft keys pre-enrolled (same as Seafile) |
| Bridge | `vmbr3` (DMZ) |
| Guest IP | `10.10.10.20/24` |
| Gateway / DNS | `10.10.10.1` (OPNsense DMZ only) |
| SSH | `debian@10.10.10.20` via `ssh dockploy` (ProxyJump `pve`) |
| Start at boot | Yes |
| Guest agent | Yes (`qemu-guest-agent` from vendor cloud-init) |

The original plan said ~14 GB RAM for a later Supabase/pgvector stack. 8 GB leaves headroom on the 32 GB host (OPNsense 3 GB, Seafile 6 GB, Scrutiny 2 GB). Raise memory in Proxmox when an app actually needs it.

Recreate path: [`configs/create-vm-103.sh`](configs/create-vm-103.sh) + [`configs/cloud-init-vendor.yml`](configs/cloud-init-vendor.yml). Image used: `debian-13-genericcloud-amd64.qcow2` in `/var/lib/vz/template/iso/` on `pve`.

---

## 3. Addresses and DNS

| Path | Address |
|------|--------|
| Panel (LAN) | `http://10.10.10.20:3000` → `/register` until the admin exists |
| Public apps | **none yet** |
| Traefik | guest `:80` and `:443` (waiting for HAProxy SNI) |

```text
LAN  :3000  ──► 10.10.10.20:3000  (Dokploy panel, Docker published)
WAN  :443   ── HAProxy TCP SNI ──► 10.10.10.20:443  (not wired)
WAN  :80    ── HAProxy HTTP Host ► 10.10.10.20:80   (not wired)
```

WAN still only routes `cloud.dustinwalker.de`. Do not mix TLS terminate on OPNsense with passthrough on the same VIP.

---

## 4. Locked application settings

Installed 2026-09-17 with `ADVERTISE_ADDR=10.10.10.20`. That flag is load-bearing: without it the installer asks a public STUN service and Docker Swarm advertises the Telekom WAN IP, which is not on this VM.

| Item | Value |
|------|--------|
| Dokploy | `dokploy/dokploy:v0.30.6` |
| Traefik | `traefik:v3.6.7` (standalone container `dokploy-traefik`) |
| Database | `postgres:16` (swarm service `dokploy-postgres`) |
| Docker | Engine 28.5.0, Swarm manager, advertise `10.10.10.20` |
| Overlay | `dokploy-network` |
| Data | `/etc/dokploy/` on the guest OS disk |

```bash
curl -sSL https://dokploy.com/install.sh | sudo ADVERTISE_ADDR=10.10.10.20 sh
```

`debian` is in group `docker`. Swarm join tokens are **not** in git; `docker swarm join-token worker` on the guest if you ever add a node.

---

## 5. Dependencies

- OPNsense DMZ interface. Existing DMZ net rules already apply (DNS/NTP, block LAN, egress 80/443). No extra rule was required for this VM.
- LAN default-allow, so house clients can hit `:3000` and SSH `:22`. WAN does not forward those.
- Guest agent on VM 103 for `qm guest exec` if SSH dies.

---

## 6. Day-2 operations

```bash
ssh dockploy
docker service ls
docker ps
docker logs dokploy-traefik --tail 100
```

Update Dokploy:

```bash
curl -sSL https://dokploy.com/install.sh | sudo ADVERTISE_ADDR=10.10.10.20 sh -s update
```

If SSH to `10.10.10.20` fails: `qm guest exec 103 -- ip -br a`

---

## 7. Open to-do

- [ ] Create the admin at http://10.10.10.20:3000 (first visitor gets `/register`)
- [ ] Pick a public hostname for the first app (and optionally the panel)
- [ ] Netlify A record to the current WAN IP
- [ ] Unbound host override → `10.10.10.20` (same split-DNS pattern as `cloud.`)
- [ ] HAProxy real servers + SNI/Host rules → `10.10.10.20:443` / `:80`, default backend still None
- [ ] Assign that hostname in Dokploy with Let's Encrypt (HTTP-01 through HAProxy `:80`)
- [ ] Only then consider `docker service update --publish-rm ... dokploy` to drop LAN `:3000`

---

## 8. Related

- [`../opnsense/`](../opnsense/) — HAProxy extension point
- [`../seafile/`](../seafile/) — working DMZ + passthrough reference
- [`../proxmox-host/`](../proxmox-host/)
