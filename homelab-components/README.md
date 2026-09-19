# Homelab components

One **folder** per system / application / component. Keep the as-built doc in that folder’s `README.md`, and drop related configs / examples beside it.

Long planning notes and cutover playbooks stay in the repo root (e.g. `homeserver-plan.md`, `ocis-public-ingress-plan.md`, `memory.md`, `opnsense-rebuild-guide.md`).

## Index

| Folder | Component | Status |
|--------|-----------|--------|
| [`proxmox-host/`](proxmox-host/) | Proxmox VE host `pve` | Live |
| [`opnsense/`](opnsense/) | OPNsense VM 100 (router, firewall, HAProxy) | Live |
| [`telekom-smart3/`](telekom-smart3/) | Speedport Smart 3 modem | Live |
| [`unifi/`](unifi/) | UniFi U7 Wi‑Fi | Live |
| [`seafile/`](seafile/) | Seafile 13 CE (private file cloud) | Live |
| [`ocis/`](ocis/) | ownCloud Infinite Scale | **Decommissioned 2026-08-17** (history) |
| [`scrutiny/`](scrutiny/) | Scrutiny SMART / drive temps (LXC 102) | Live |
| [`dockploy/`](dockploy/) | Dockploy / public apps | Live (LAN panel; no public hostname yet) |

## Folder layout

```text
homelab-components/<name>/
  README.md           # as-built reference (required)
  *.example / configs # sanitized examples OK
  # never commit: .env, *.xml backups with secrets, tokens
```

## What each README should cover

1. **Role**  
2. **Where it runs**  
3. **Addresses & DNS**  
4. **Locked settings** (no secrets)  
5. **Dependencies**  
6. **Day-2 ops**  
7. **Links** to plans and configs in this folder  

**Do not** commit passwords, API tokens, or full OPNsense / Smart 3 XML exports.
