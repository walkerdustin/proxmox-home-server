# Public ingress plan (DMZ + HAProxy SNI + reverse proxy in the VM)

**Status:** **Executed** 2026-08-16; still accurate  
**Last updated:** 2026-08-17  
**Supersedes:** ad-hoc “terminate TLS on OPNsense” shortcut; aligns with `homeserver-plan.md` §5.

> **Read “Traefik” as “the VM's reverse proxy” throughout.** Written for oCIS,
> which used Traefik. Since 2026-08-17 the VM runs Seafile with **Caddy**
> instead, and the swap required **no change** to DNS, HAProxy, the WAN rules,
> or the split-DNS override — the LE HTTP-01 challenge validated through this
> exact path on the first attempt. Everything here about SNI passthrough,
> keeping WAN `:80` open for renewals, TCP-mode health checks, and moving the
> OPNsense GUI off 443 is unchanged and still load-bearing.
> Current stack: [`homelab-components/seafile/README.md`](homelab-components/seafile/README.md).

---

## 1. Locked decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Ingress model | **HAProxy TCP SNI passthrough** on `:443` + **HTTP Host** on `:80` | Fits Dockploy/Traefik later; no mixed terminate/passthrough |
| TLS termination | **On the oCIS VM** (official Traefik) | Each app VM owns certs the way its stack expects |
| oCIS deploy | **Official `ocis_full` Compose** | Documented prod path, upgrades, LE built-in |
| Collabora / OnlyOffice | **Off** | User choice; saves RAM on 6 GB VM |
| Tika (full-text search) | **On** | Content search; cheaper than office; no public domain needed |
| Public hostname | `cloud.dustinwalker.de` | Single name for oCIS |
| DNS | **Netlify DNS** (Porkbun = registrar only) | Records edited in Netlify |
| DMZ | `10.10.10.0/24`, GW `10.10.10.1`, oCIS `10.10.10.10` | Already configured |
| oCIS ports on VM | Traefik **`:80` + `:443`** → oCIS internally | LE HTTP-01 + HTTPS |
| Future Dockploy | Same HAProxy pattern: SNI/Host → Dockploy `:443`/`:80` | Add rules later; no redesign |

```text
Internet
  :443 ── HAProxy (TCP, SNI) ──► 10.10.10.10:443  (Traefik)
  :80  ── HAProxy (HTTP, Host) ─► 10.10.10.10:80   (Traefik ACME + redirect)

LAN clients
  ideally resolve cloud.dustinwalker.de → 10.10.10.10 (split DNS)
  OR use NAT reflection / hairpin (worse; avoid if possible)
```

---

## 2. Current baseline (do not assume)

**Already done**

- `vmbr3` DMZ; OPNsense `vtnet2` / DMZ `10.10.10.1/24`
- VM 101 `ocis` on `vmbr3`, static `10.10.10.10/24`, gw `10.10.10.1`
- LAN ↔ DMZ reachability (after fixing `169.254` link-local default route)
- Mini Compose: `owncloud/ocis:8.2.0` on `:9200`, data under `/mnt/data/ocis/`
- TEMP firewall: DMZ → any; LAN default allow any (+ explicit LAN→DMZ)

**Not done**

- Public DNS / DynDNS
- `os-haproxy` plugin
- WAN `:80`/`:443` allow → HAProxy
- Official Traefik stack + LE
- Firewall hardening (replace TEMP rules)
- Client re-point to public URL

---

## 3. Edge cases & mitigations

### 3.1 Networking / DMZ

| Edge case | Risk | Mitigation |
|-----------|------|------------|
| `169.254.x.x` + on-link default returns | LAN cannot reach oCIS; ARP for LAN IPs on DMZ | Keep `auto ens18` **static** only; no DHCP client; after every reboot verify `ip route` has `default via 10.10.10.1` and **no** `169.254` |
| Guest SSH only via DMZ | Lose access if IP breaks | Keep qemu-guest-agent; recover via `qm guest exec` / Proxmox console |
| TEMP `DMZ → any` | DMZ can scan LAN | After public works: allow DMZ → WAN (or any for updates) but **block DMZ → LAN** except what you explicitly need (usually nothing) |
| Publishing SSH | Attack surface | **Never** forward `:22` from WAN; admin via LAN/VPN only |
| Proxmox on `vmbr3` | Host exposed to DMZ | Keep **no host IP** on `vmbr3` |

### 3.2 DNS / Telekom WAN

| Edge case | Risk | Mitigation |
|-----------|------|------------|
| Dynamic WAN IP | `cloud.` points at old IP; LE/clients fail | DynDNS from OPNsense updating Netlify (or CNAME to a DynDNS name Netlify can alias). Verify update after reboot / IP change |
| High DNS TTL | Slow failover after IP change | TTL 300s (or Netlify Auto) for `cloud` A record |
| **Hairpin / NAT loopback** | Phone on Wi‑Fi uses public IP; return path breaks or is flaky | Prefer **split DNS**: Unbound host override `cloud.dustinwalker.de` → `10.10.10.10` for LAN. Test from Wi‑Fi **and** from mobile data |
| CGNAT | No inbound `:80`/`:443` | Confirm WAN shows a public address (not `100.64.0.0/10`). Telekom DSL usually OK; if CGNAT, inbound hosting needs a tunnel (out of scope) |
| Registrar vs DNS mix-up | Editing Porkbun while Netlify is authoritative | Change records only in **Netlify**; Porkbun NS must point at Netlify |

### 3.3 Let’s Encrypt / Traefik

| Edge case | Risk | Mitigation |
|-----------|------|------------|
| Rate limits | Locked out of issuance | Always **staging** ACME first; only then production; delete staging volume/certs before switching |
| Port 80 closed / not forwarded | HTTP-01 fails | HAProxy must forward Host `cloud.dustinwalker.de` `:80` → `10.10.10.10:80` before expecting a real cert |
| Wrong `OCIS_DOMAIN` / DNS lag | NXDOMAIN / wrong host cert | `nslookup` from outside before `compose up`; wait for DNS |
| Cert renewals | Breaks every ~60–90 days | Leave `:80` path in place permanently; Traefik renews on its own |
| Clock skew | ACME/TLS failures | Ensure VM NTP works (DMZ → WAN UDP/123 or via OPNsense) |

### 3.4 Migrating from mini Compose → `ocis_full`

| Edge case | Risk | Mitigation |
|-----------|------|------------|
| Losing existing files/users | Data loss | Snapshot ZFS `tank` / VM disk **before** cutover; bind `OCIS_CONFIG_DIR` + `OCIS_DATA_DIR` to existing `/mnt/data/ocis/{config,data}` (or documented migrate path); **do not** `docker compose down -v` |
| Two stacks fighting ports | Bind errors | Stop/remove old `~/ocis` compose **before** starting Traefik on `:80`/`:443` |
| `OCIS_URL` / domain change | OIDC redirects, clients break | Set `OCIS_DOMAIN=cloud.dustinwalker.de`; re-login desktop/mobile clients; expect one-time re-auth |
| `ocis init` already done | Secrets already in config | Do **not** wipe config unless intentional reset; official stack should reuse config dir |
| Admin password / demo users | Insecure defaults | Set strong `ADMIN_PASSWORD` if required by stack; `DEMO_USERS=false` |
| Office leftovers | Extra RAM/domains | Comment `COLLABORA=…` and OnlyOffice; no `collabora.*` DNS needed |
| Tika RAM during bulk upload | VM pressure on 6 GB | Keep default 20 MB extract limit; watch `free -h` during big syncs; Tika is internal-only (no public port) |
| Image channel | Surprise upgrades | Pin `OCIS_DOCKER_IMAGE=owncloud/ocis` and a known tag (e.g. `8.2.0`), not floating `latest` / rolling unless you choose rolling deliberately |

### 3.5 HAProxy / firewall

| Edge case | Risk | Mitigation |
|-----------|------|------------|
| HAProxy not installed | — | Install `os-haproxy`; enable service; no listen on WAN until rules ready |
| WAN rule too wide | Exposes wrong ports | WAN allow **TCP 80 and 443 only** to HAProxy (or “this firewall”); not to DMZ net wholesale |
| Backend health checks on TLS | False DOWN | Use TCP checks or disable checks initially for passthrough |
| SNI mismatch / missing inspect-delay | Intermittent 443 | Use documented `tcp-request inspect-delay` + `req.ssl_hello_type 1` before SNI ACLs |
| Default backend | Random hits | Default = reject/close; only `cloud.` (later `*.` for Dockploy) |
| IPv6 | Half-broken dual-stack | Keep IPv6 **off** until intentionally designed |
| OPNsense reboot order | Brief outage | HAProxy on boot; oCIS `restart: unless-stopped`; document expected 1–2 min blip |

### 3.6 Clients & security

| Edge case | Risk | Mitigation |
|-----------|------|------------|
| Old bookmark `https://10.10.10.10:9200` | Cert/name errors | Update to `https://cloud.dustinwalker.de`; stop publishing `:9200` publicly (internal-only or drop host publish after Traefik) |
| Sharing links | Must use public hostname | Verify share URLs after cutover |
| Friends on internet | Brute force / scanners | Strong passwords; consider fail2ban later; no SSH; optional Authelia later (not now) |
| Backup still valid | URL change irrelevant to Kopia paths | Kopia still reads data dir; schedule after stack stable |

### 3.7 Rollback triggers (stop and revert)

Stop the phase and roll back if:

- Cannot get LE **staging** cert after DNS + `:80` verified  
- Existing oCIS data not visible after bind-mount cutover  
- LAN loses management of OPNsense/Proxmox while changing WAN rules  
- WAN IP is CGNAT / inbound ports never reach HAProxy  

**Rollback knobs (in order):** disable WAN 80/443 rules → stop HAProxy frontend → `docker compose down` new stack → start old mini compose on `:9200` → restore ZFS/VM snapshot if data wrong.

---

## 4. Execution phases

### Phase A — Backups (before any public exposure)

1. OPNsense: export config XML (local only; **do not commit secrets**).  
2. Proxmox: snapshot VM 101 (or ZFS snap of `tank` dataset used by scsi1).  
3. On oCIS: note `docker compose ps`, copy `~/ocis/docker-compose.yml`, confirm `/mnt/data/ocis` sizes.  
4. Record current WAN IPv4 from OPNsense Overview.

**Gate:** snapshots + XML saved; WAN IP written down.

### Phase B — DNS + DynDNS

1. Netlify: `A` record `cloud` → current WAN IP (TTL low).  
2. From outside path: `nslookup cloud.dustinwalker.de` matches WAN.  
3. Configure OPNsense Dynamic DNS to keep that record updated (Netlify-compatible method or CNAME→supported DynDNS provider).  
4. OPNsense Unbound: host override `cloud.dustinwalker.de` → `10.10.10.10` (split DNS).  

**Gate:** external DNS correct; LAN resolves to `10.10.10.10`; DynDNS test documented.

### Phase C — HAProxy + WAN firewall (empty backends first OK)

1. Install/enable `os-haproxy`.  
2. Real server: `10.10.10.10:443` and `:80`.  
3. Backend pools: TCP mode for HTTPS; HTTP mode for HTTP.  
4. Public service `:443` TCP + SNI ACL `cloud.dustinwalker.de` → HTTPS pool; default reject.  
5. Public service `:80` HTTP + Host ACL → HTTP pool (ACME); optional redirect later once Traefik handles it.  
6. WAN rules: allow TCP 80, 443 to HAProxy.  

**Gate:** from mobile data, `Test-NetConnection cloud.dustinwalker.de -Port 443` (and 80) reaches something on the VM (even connection reset is OK before Traefik); LAN still healthy.

### Phase D — Official oCIS stack (Collabora off, Tika on)

1. Stop old mini compose; free `:9200` host publish if needed.  
2. Install official compose under e.g. `/opt/compose/ocis/ocis_full`.  
3. `.env` essentials:  
   - `INSECURE` commented/false  
   - `TRAEFIK_ACME_MAIL=<your mail>`  
   - `TRAEFIK_ACME_CASERVER=<staging URL>` first  
   - `OCIS_DOMAIN=cloud.dustinwalker.de`  
   - `OCIS_DOCKER_IMAGE=owncloud/ocis`, pin tag  
   - `# COLLABORA=...` commented  
   - `TIKA=:tika.yml` enabled  
   - Bind config/data to `/mnt/data/ocis/...`  
   - `DEMO_USERS=false`  
4. `docker compose up -d`; watch Traefik logs for staging cert.  
5. Switch ACME to production (clear staging certs per docs); verify browser shows real LE issuer.  
6. Log in; confirm users/files; test Tika with a small PDF upload + search.  

**Gate:** `https://cloud.dustinwalker.de` works on mobile data **and** Wi‑Fi; files intact; staging→prod LE done.

### Phase E — Harden

1. Replace TEMP DMZ outbound with: allow DNS, HTTP/HTTPS, NTP (and what updates need); **deny DMZ→LAN**.  
2. Keep LAN→DMZ 80/443 (and SSH from LAN if desired).  
3. Disable diagnostic firewall logging left from earlier.  
4. Confirm `:9200` not exposed on WAN; optionally bind oCIS only on Docker network.  
5. Update `memory.md` / this plan status; export fresh OPNsense XML.

**Gate:** nmap-from-WAN mindset: only 80/443; DMZ cannot hit `192.168.1.0/24`.

### Phase F — Clients & soak

1. Repoint desktop/mobile apps to `https://cloud.dustinwalker.de`.  
2. Test share link from a friend network.  
3. Reboot oCIS VM once; confirm no `169.254`, Traefik comes back, certs persist.  
4. Reboot OPNsense once; HAProxy + forwarding still work.  
5. Soak several days before Dockploy.

---

## 5. Explicit non-goals (this plan)

- Collabora / OnlyOffice  
- TLS termination on OPNsense for `cloud.`  
- Mixed terminate + passthrough on one VIP  
- IPv6  
- Dockploy install (only leave HAProxy extension points)  
- Kopia offsite (separate later)  
- Exposing Proxmox or OPNsense GUI to WAN  

---

## 6. Success criteria

- [ ] `https://cloud.dustinwalker.de` loads with a **trusted** LE cert from internet  
- [ ] Same URL works on home Wi‑Fi (split DNS)  
- [ ] Existing users/files present after migration  
- [ ] Search finds content inside a test document (Tika)  
- [ ] No Collabora containers running  
- [ ] WAN only needs 80/443; SSH not public  
- [ ] After VM + OPNsense reboot, service returns without manual `169.254` surgery  
- [ ] Documented rollback still possible via snapshot + old compose file  

---

## 7. Immediate next step

**Phase A (backups), then Phase B (DNS + DynDNS + Unbound override).**  
Do not install the official stack until external DNS for `cloud.dustinwalker.de` answers correctly.
