# OPNsense (VM 100)

**Status:** Production edge router  
**Last verified:** 2026-08-22  
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
| DNS | Unbound, **forwarding** to Cloudflare filtered resolvers — see below |
| Split DNS | Host override `cloud.dustinwalker.de` → `10.10.10.10` |
| DynDNS | **Not automated** yet — Netlify A record updated manually when WAN IP changes |

### 3.1 DNS resolver — Unbound forwarding to `1.1.1.3` (2026-08-22)

Unbound ships as a **recursive** resolver: it walks the root servers itself and never
consults an upstream. Setting DNS servers under System → Settings → General alone
therefore has **no effect on client lookups** — that field governs only OPNsense's own
resolution. Forwarding must be enabled explicitly.

| Where | Setting |
|-------|---------|
| System → Settings → General | DNS servers `1.1.1.3` + `1.0.0.3`; **uncheck** *Allow DNS server list to be overridden by DHCP/PPP on WAN* |
| Services → Unbound DNS → Query Forwarding | Two entries, Domain **empty** (= root, forward everything): `1.1.1.3:53`, `1.0.0.3:53` — both with **Forward first** on |
| Services → Unbound DNS → Advanced | *Prefetch Support* on · Message Cache `64m` · RRset Cache `128m` |

`1.1.1.3` is Cloudflare's malware **+ adult content** filter (`1.1.1.1` plain,
`1.1.1.2` malware only). Blocked names answer `0.0.0.0` / `::`.

The WAN-override uncheck is not cosmetic: left enabled, Telekom's PPPoE injects its own
resolvers and *prepends* them, giving intermittently unfiltered DNS that looks random
rather than broken.

Gotchas learned building this:

- **"Use System Nameservers" no longer exists.** Older guides reference a checkbox on the
  Query Forwarding page; current versions use explicit entries only. Once entries exist,
  Unbound ignores System → Settings → General completely.
- **Empty `Domain` means forward everything.** Filling it in forwards only that one zone
  and recurses for the rest.
- **`Forward first` is a per-entry GUI checkbox.** No `unbound.conf` include needed —
  plans to hand-write a `forward-zone` block under `/usr/local/etc/unbound.opnsense.d/`
  turned out to be unnecessary.
- **Blocked + DNSSEC-signed names return SERVFAIL, not `0.0.0.0`.** A filtering resolver's
  synthetic answer is, to a validating resolver, a lie. Both outcomes block the site; the
  error just looks different. Not a misconfiguration.
- **Split DNS still wins.** Host overrides are answered locally before anything is
  forwarded, so `cloud.dustinwalker.de` is unaffected.
- **The DMZ inherits this filter**, because DMZ rule 1 (§6) forces `10.10.10.1` as its
  only resolver. Seafile's own lookups now pass through Cloudflare's filter too.
- **Cloudflare's own test domains are unreliable.** `adult.testcategory.com` returned a
  real address while filtering was demonstrably working. Verify with a domain known to be
  categorised instead.
- **Measured on this line:** recursive Unbound was already doing 15–50 ms cold lookups, so
  forwarding was **not** a speed win. This change buys filtering, not performance.

**Accepted risk — `Forward first`.** If Cloudflare becomes unreachable, Unbound falls back
to full recursion, which means **unfiltered answers, silently, with no error anywhere**.
Kept deliberately, choosing availability over enforcement. Mitigation is a to-do: an
active check that resolves a known-blocked name through `192.168.1.1` and mails when the
sentinel stops coming back — same pattern as
[`../proxmox-host/configs/drive-temp-alert.sh`](../proxmox-host/configs/drive-temp-alert.sh).

### 3.2 Considered and declined (2026-08-22)

| Idea | Why not |
|------|---------|
| NAT redirect LAN → `127.0.0.1:53` | Would force devices with hardcoded DNS through Unbound, closing the "just set my laptop to `8.8.8.8`" bypass. Skipped for simplicity; nothing depends on it and it can be added any time. It lives under Firewall → NAT → **Destination NAT** — *not* "Port Forward", which is what older guides call it. It would also capture the Proxmox host's `1.1.1.1` fallback, making that fallback decorative |
| Block outbound TCP/UDP **853** (DoT / DoQ) | **Would break the phones.** Android *Private DNS* and iOS configuration profiles reach `1.1.1.3` **over port 853**; in strict mode there is no fallback, so this rule kills DNS on Wi-Fi for exactly the devices that are already filtered everywhere they go. **Do not add it.** |

Neither closes **DoH**, which rides ordinary HTTPS to CDN-looking hosts and cannot be
blocked by port. That is switched off per browser instead (Chrome
`chrome://settings/security`, Firefox → Privacy & Security → DNS over HTTPS), and it
remains the largest hole by a wide margin.

### 3.3 Static addressing convention

| Range | Use |
|-------|-----|
| `.1`–`.29` | Infrastructure — `.1` OPNsense, `.10` Proxmox, `.20` Scrutiny LXC 102 |
| `.30`–`.59` | IoT / home automation reservations |
| `.100`–`.200` | DHCP pool |

Reserving outside the pool means a reservation can never collide with a live lease.

| Device | Address | Why it must not move |
|--------|---------|----------------------|
| `esp32-6ADCB0` — desk light | `192.168.1.30` | An Android *Automate* flow fires `http://<ip>/alarm` when the morning alarm goes off, starting a sunrise fade. A lease change breaks the alarm **silently**: the symptom is "the light didn't come on", noticed once, with nothing logged anywhere |

**Reservations are created from the leases list, not typed in.** The Reservations / Hosts
tab looks empty and unhelpful; the `+` button in the **Commands** column of each lease row
pre-fills subnet, IP and MAC. Then edit the IP and Apply, and power-cycle the device so it
drops its old lease.

**Check which DHCP server is authoritative before adding a reservation.** Both **Kea DHCP**
and **Dnsmasq DNS & DHCP** appear in the Services menu, and a reservation entered into the
inactive one is a **silent no-op** — the device keeps its pool address and nothing
explains why. Leases showing `IAID` / `DUID` columns are Kea's.

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

## 6. Firewall (as built, DMZ hardened 2026-08-18)

| Interface | Rule | Notes |
|-----------|------|--------|
| WAN | Pass TCP **443** → WAN address | HAProxy HTTPS |
| WAN | Pass TCP **80** → WAN address | HAProxy / ACME |
| LAN | Default allow IPv4 + IPv6 | Legacy looseness; also what makes **LAN → DMZ SSH** work |

### DMZ rules — order matters (first match wins, `Quick` on all)

| # | Action | Proto | Source | Destination | Port | Log | Why |
|---|--------|-------|--------|-------------|------|-----|-----|
| 1 | Pass | TCP/UDP | DMZ net | **DMZ address** | 53 | — | OPNsense is the **only** resolver, so every lookup from the DMZ is visible/blockable here |
| 2 | Pass | UDP | DMZ net | any | 123 | — | `systemd-timesyncd` → Debian NTP pool. Clock skew breaks TLS **and** ACME renewal |
| 3 | **Block** | any | DMZ net | **LAN net** | any | **yes** | The actual point of the DMZ: no lateral movement into the house LAN or Proxmox |
| 4 | **Block** | any | DMZ net | **This Firewall** | any | **yes** | Keeps VM 101 off the OPNsense GUI/SSH |
| 5 | Pass | TCP | DMZ net | any | 80 | — | apt, ACME http-01 |
| 6 | Pass | TCP | DMZ net | any | 443 | — | apt, Docker Hub, ACME |
| 7 | Pass | TCP | DMZ net | any | **465** | — | Zoho SMTP. **Remove this and Seafile mail dies with no error anywhere** |
| 8 | Pass | ICMP | DMZ net | any | — | — | ping, for troubleshooting |
| — | *(disabled)* | | | | | | `TEMP allow DMZ outbound` — kept disabled, not deleted, as a one-click revert |

Gotchas learned building this:

- **Rules 1–2 must sit above 3–4.** DNS/NTP are permitted *before* the blocks, or name resolution dies.
- **Build new rules while the TEMP allow-any is still on top.** New rules append to the bottom and stay inert until TEMP is disabled — so the whole set can be built and applied with zero risk, then flipped with one toggle.
- **Never set Interface = `any`.** That silently makes it a **floating** rule, which is evaluated *before* interface rules. A floating `Block DMZ net → any` cuts the VM off completely.
- **`Destination: any` on a block rule blocks everything**, not just what the description says. Both blocks need an explicit destination (`LAN net` / `This Firewall`).
- **Port 465 shows as `igmpv3lite`** in the rule list — cosmetic, that is FreeBSD's `/etc/services` name. The rule is correct.
- **Blocking `DMZ → This Firewall` does not break HAProxy.** HAProxy connects *from* OPNsense to `10.10.10.10:80`; interface rules filter inbound only, and replies match an existing pf state.
- **Blocked traffic times out rather than refusing** (`timeout` exit 124), which is intended — a silent drop tells a scanner nothing.

Verified from VM 101 after the flip: DNS resolves, HTTPS 200, TLS handshake to `smtp.zoho.eu:465`, `NTPSynchronized=yes`; and `192.168.1.10` (ping + `:8006`) plus `10.10.10.1` all time out.

**Future:** a Kopia seed to a LAN host would need an explicit pass rule placed **above** rule 3.

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
