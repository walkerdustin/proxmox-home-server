# OPNsense (VM 100)

**Status:** Production edge router  
**Last verified:** 2026-08-16  
**GUI:** https://192.168.1.1:8443 (LAN only)  
**LAN gateway:** `192.168.1.1/24`

Rebuild playbook: [`../../opnsense-rebuild-guide.md`](../../opnsense-rebuild-guide.md) · Facts: [`../../memory.md`](../../memory.md)

---

## 1. Role

Edge firewall/router for the house: Telekom PPPoE, LAN DHCP/DNS, DMZ, and Layer-4 ingress (HAProxy SNI/HTTP) to app VMs. Does **not** terminate TLS for `cloud.*` (passthrough to Traefik on oCIS).

---

## 2. Where it runs

| Item | Value |
|------|--------|
| Proxmox VM | **100** `opnsense` |
| Version | OPNsense **26.7.x** |
| RAM / vCPU | **3072 MB** / 2 (CPU weight **4096**) |
| Boot disk | UFS (not nested ZFS) |
| Start at boot | **Yes** |

### Interfaces (guest ↔ Proxmox)

| OPNsense | Bridge | Role | Address |
|----------|--------|------|---------|
| `vtnet0` | `vmbr1` / `nic1` | WAN parent | — |
| `vlan01` tag **7** on `vtnet0` | — | Telekom VLAN | — |
| `pppoe0` on `vlan01` | — | **Assigned WAN** | Public IPv4 (dynamic) |
| `vtnet1` | `vmbr0` / `nic2` | LAN | `192.168.1.1/24` |
| `vtnet2` | `vmbr3` | DMZ | `10.10.10.1/24` |

WAN: Block private networks + bogons **on**; IPv6 **none** for now.  
PPPoE username format: `Anschlusskennung#Zugangsnummer@t-online.de` (secret — not in git).

**VLAN tip:** After creating VLAN 7, **Apply** and confirm `vlan01` exists at runtime.

---

## 3. LAN services

| Service | Setting |
|---------|---------|
| DHCP | On LAN; pool `192.168.1.100`–`192.168.1.200` |
| DNS | Unbound |
| Split DNS | Host override `cloud.dustinwalker.de` → `10.10.10.10` |
| DynDNS | **Not automated** yet — Netlify A record updated manually when WAN IP changes |

---

## 4. Web GUI (locked for HAProxy)

So HAProxy can bind public `:80` / `:443`:

| Setting | Value |
|---------|--------|
| Protocol | HTTPS |
| TCP port | **8443** |
| Listen interfaces | **LAN** (not All) |
| Disable web GUI redirect rule | **Checked** (frees port 80) |

Reach UI at `https://192.168.1.1:8443` from the house LAN only.

---

## 5. HAProxy (`os-haproxy`)

**Model:** TCP SNI passthrough on 443; HTTP Host routing on 80. Default backends **None** (unknown hosts not forwarded).

### Real servers

| Name | Target |
|------|--------|
| `ocis-https` | `10.10.10.10:443` (SSL off) |
| `ocis-http` | `10.10.10.10:80` (SSL off) |

### Backend pools

| Name | Mode | Server |
|------|------|--------|
| `ocis-https-pool` | TCP L4 | `ocis-https` (health checks off) |
| `ocis-http-pool` | HTTP L7 | `ocis-http` (health checks off) |

### Conditions / rules

| Name | Purpose |
|------|---------|
| `tls-hello` | Custom `req.ssl_hello_type 1` |
| `cloud-sni` | SNI = `cloud.dustinwalker.de` |
| `cloud-host` | Host header contains `cloud.dustinwalker.de` |
| `inspect-delay-5s` | `tcp-request` inspect-delay `5s` |
| `accept-tls-hello` | `tcp-request` content accept |
| `route-cloud-https` | → `ocis-https-pool` |
| `route-cloud-http` | → `ocis-http-pool` |

### Public services

| Name | Listen | Type | Rules |
|------|--------|------|--------|
| `wan-https` | `0.0.0.0:443` | SSL/HTTPS (TCP mode), SSL offloading **off** | inspect-delay → accept-tls-hello → route-cloud-https |
| `wan-http` | `0.0.0.0:80` | HTTP, SSL offloading **off** | route-cloud-http |

Later Dockploy: add SNI/Host rules + pools the same way (no redesign).

---

## 6. Firewall (current intent)

| Interface | Rule | Notes |
|-----------|------|--------|
| WAN | Pass TCP **443** → WAN address | HAProxy HTTPS |
| WAN | Pass TCP **80** → WAN address | HAProxy / ACME |
| LAN | Default allow (plus explicit LAN→DMZ as needed) | TEMP / legacy looseness |
| DMZ | TEMP allow outbound broadly | **Harden later** — allow DNS/HTTP(S)/NTP; **block DMZ→LAN** |

Do **not** publish SSH or OPNsense GUI on WAN.

---

## 7. Day-2 ops

- Config backup: **System → Configuration → Backups** — store privately; **never commit XML**
- After WAN IP change: update Netlify `cloud` A record (TTL prefer 300 until DynDNS exists)
- HAProxy: **Services → HAProxy → Statistics** (frontends OPEN; counters)
- Syntax: HAProxy **Save & Test syntax** / Apply

---

## 8. Common failures

| Symptom | Likely cause |
|---------|----------------|
| Public 80/443 timeout, HAProxy OPEN | Stale public DNS vs current `pppoe0` IP |
| PPPoE down after VLAN change | VLAN not Applied / wrong parent |
| HAProxy won’t bind 443 | GUI still on 443 or listen All |
| Port 80 conflict | GUI HTTP redirect still enabled |
| DMZ↔LAN broken | Missing rules or guest `169.254` route |

---

## 9. Related components

- Modem: [`../telekom-smart3/`](../telekom-smart3/)  
- Host bridges: [`../proxmox-host/`](../proxmox-host/)  
- Cloud app: [`../ocis/`](../ocis/)  
- Configs for this component: keep sanitized examples in this folder (never commit live XML)  
