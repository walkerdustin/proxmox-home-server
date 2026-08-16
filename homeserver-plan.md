### System- und Architektur-Dokumentation: Proxmox Home-Server (Konzept)

Dieses Dokument enthält die vollständige technische Spezifikation und Architekturplanung für den Aufbau eines sicheren Home-Servers auf Basis von Proxmox VE. Es dient als "Single Source of Truth" für die schrittweise Installation und Konfiguration.

#### 1. Projektübersicht und Phasen-Planung
Das System fungiert als primärer Router/Firewall für das Heimnetzwerk und hostet gleichzeitig öffentlich erreichbare Web-Anwendungen (Dockploy) sowie einen Cloud-Speicher für Freunde (Seafile). 
Um Stabilität zu garantieren, erfolgt der Aufbau in zwei Phasen:
*   **Phase 1 (Basis-Setup) — erledigt:** Proxmox, OPNsense als Edge-Router (PPPoE/VLAN 7), Smart 3 im Modem-Modus, UniFi-AP am LAN, Host-RAM auf 32 GB. Details: `memory.md`, Rebuild: `opnsense-rebuild-guide.md`.
*   **Phase 2 (Apps & Ingress):** Hinzufügen der VMs für Dockploy und Seafile sowie Einrichtung des Ingress-Routings (DMZ, HAProxy/SNI). RAM-Upgrade ist bereits erfolgt.

#### 2. Hardware-Spezifikationen & Storage-Setup
*   **CPU:** Intel Core i5-6600K (4 Kerne, 4 Threads, unterstützt AES-NI).
*   **RAM:** **32 GB DDR4** (4×8 GB, gemischt Kingston/Corsair; läuft typischerweise JEDEC **2133 MT/s**). Nutzbar im OS ca. 31,2 GiB.
*   **Netzwerk (Physisch):**
    *   1x Onboard LAN-Port (Mainboard) — Emergency `nic0` / `vmbr2`.
    *   1x PCIe-Netzwerkkarte (10Gtek Intel I350-T2, Dual-Port, 1 GbE) — WAN `nic1`, LAN `nic2`.
*   **Speicher (OS & VMs - SSDs):** 
    *   1x 250 GB SSD und 1x 500 GB SSD als **ZFS Mirror (RAID 1)** (`rpool`). Nutzbar initial ~250 GB. Später 250→500 GB per Resilvering/`autoexpand=on` möglich.
    *   1x 125 GB SSD bleibt vorerst ungenutzt (später lokales Backup-Laufwerk).
*   **Speicher (Daten - HDDs):** 3x 2 TB HDDs (3,5 Zoll) — Phase 2 / Seafile.
*   **Infrastruktur:** Telekom VDSL ~50 Mbit/s (später Glasfaser). Speedport Smart 3 im **Modem-Modus** (Ausgang **LAN 4**). PoE-Switch + **UniFi U7** im LAN hinter OPNsense (Smart-3-WLAN aus).

#### 3. Netzwerk-Topologie & Physische Verkabelung
Das Netzwerk-Routing wird über Linux Bridges in Proxmox gelöst. Es gilt das "Emergency Backdoor"-Konzept zur Absicherung des Management-Zugriffs:
*   **WAN (`vmbr1`):** Port 1 der PCIe-Karte. Physisch mit dem Modem verbunden. Proxmox hat hier *keine* IP. Wird an OPNsense für PPPoE durchgereicht.
*   **LAN (`vmbr0`):** Port 2 der PCIe-Karte. Physisch mit dem Switch verbunden. Proxmox bezieht hier seine **Haupt-Management-IP** (z. B. 192.168.1.10). OPNsense fungiert hier als Gateway (192.168.1.1) und DHCP-Server.
*   **Notfall-Port (`vmbr2`):** Onboard LAN-Port. Bleibt **physisch leer**. Erhält eine statische IP aus einem isolierten Netz (z. B. 10.99.99.1). Dient dem direkten Laptop-Zugriff, falls OPNsense oder der Switch ausfallen.
*   **DMZ (`vmbr3`):** Virtuelle Brücke *ohne* physischen Port. Proxmox hat hier *keine* IP. Hier befinden sich die Dockploy-VM und die Seafile-VM. Jeglicher Traffic zwischen DMZ und LAN muss die OPNsense-Firewall passieren.

#### 4. Virtuelle Maschinen & Ressourcen-Zuteilung
Es wird **kein CPU-Pinning** verwendet. Die Priorisierung erfolgt über Proxmox CPU Units (Weights), um die 4 physischen Kerne optimal auszulasten.

*   **VM 1: OPNsense (Router & Firewall)** — läuft
    *   **CPU:** 2 vCores. **Priorität (CPU Weight): 4096** (Realtime-Priorität für Routing).
    *   **RAM:** **3 GB** (3072 MB; 2 GB zu knapp für Install/Betrieb).
    *   **Aufgabe:** PPPoE (VLAN 7), DHCP, Firewall, später Ingress-Routing (Layer 4).
*   **VM 2: Dockploy (Public Apps)** — Phase 2
    *   **CPU:** 4 vCores. Priorität: 1024 (Standard).
    *   **RAM:** Ziel ca. 14 GB (bei 32 GB Host).
    *   **Aufgabe:** Docker-Host, Traefik, Supabase (pgvector). Befindet sich in der DMZ.
*   **VM 3: Seafile (Private Storage / Cloud)** — Phase 2
    *   **CPU:** 2 vCores. Priorität: 1024 (Standard).
    *   **RAM:** Ziel ca. 8 GB.
    *   **Aufgabe:** Cloud-Speicher für Freunde (öffentlich erreichbar ohne VPN). Befindet sich zwingend in der DMZ.

#### 5. Ingress, Routing & SSL-Konzept
*   **Domain:** `dustinwalker.de` (Porkbun registrar, **Netlify DNS**). DynDNS via OPNsense keeping public records updated.
*   **Public name (storage):** `cloud.dustinwalker.de` → oCIS VM in DMZ (`10.10.10.10`).
*   **SSL Passthrough (Layer 4):** OPNsense HAProxy does **not** terminate TLS on `:443`. It routes by SNI only:
    *   `cloud.dustinwalker.de` → oCIS VM `:443` (Traefik)
    *   Later: app hostnames / `*.…` → Dockploy Traefik `:443`
*   **HTTP `:80`:** HAProxy routes by `Host` to the same VMs for Let’s Encrypt HTTP-01 (and redirects).
*   **SSL-Termination:** On each app VM. oCIS uses the **official Compose stack (Traefik + LE)**; Collabora **off**; Tika **on**. Dockploy keeps its own Traefik later.
*   **LAN access:** Split DNS (Unbound override → `10.10.10.10`) to avoid hairpin NAT issues.
*   **Detail plan / edge cases:** [`ocis-public-ingress-plan.md`](ocis-public-ingress-plan.md).

#### 6. Storage-Konfiguration (ZFS) & Backup
*   **ZFS-Pool (HDDs):** Die 3x 2 TB HDDs werden im Proxmox-Host als **RAIDZ1** konfiguriert (ca. 3,5 TB nutzbar).
*   **Zuweisung:** Auf dem RAIDZ1-Pool wird eine virtuelle Festplatte (`.raw`) erstellt und an die Seafile-VM durchgereicht.
*   **ZFS-Tuning:**
    *   ZFS ARC (RAM-Cache) in Proxmox limitieren: bisher Phase-1-Ziel 2 GB; mit 32 GB Host und HDD-Pool **ca. 4 GB** sinnvoll, sobald RAIDZ1 aktiv ist.
    *   Kompression (LZ4/ZSTD) ist aktiviert. Deduplizierung ist strikt deaktiviert.
    *   `sync=standard` bleibt aktiviert (Schutz vor Datenverlust, da keine USV vorhanden).
    *   Kein HDD-Spindown (Standby), um die Mechanik bei ZFS-Nutzung zu schonen.
*   **Backup:** Automatisierte ZFS-Snapshots der Seafile-VM auf dem Proxmox-Host (z. B. via `sanoid`). Später Einrichtung von VM-Backups auf die dedizierte 125 GB SSD.
