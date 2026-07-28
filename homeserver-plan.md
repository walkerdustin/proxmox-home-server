### System- und Architektur-Dokumentation: Proxmox Home-Server (Konzept)

Dieses Dokument enthält die vollständige technische Spezifikation und Architekturplanung für den Aufbau eines sicheren Home-Servers auf Basis von Proxmox VE. Es dient als "Single Source of Truth" für die schrittweise Installation und Konfiguration.

#### 1. Projektübersicht und Phasen-Planung
Das System fungiert als primärer Router/Firewall für das Heimnetzwerk und hostet gleichzeitig öffentlich erreichbare Web-Anwendungen (Dockploy) sowie einen Cloud-Speicher für Freunde (Seafile). 
Um Stabilität zu garantieren, erfolgt der Aufbau in zwei Phasen:
*   **Phase 1 (Basis-Setup mit 16 GB RAM):** Installation von Proxmox und Einrichtung der OPNsense-VM als Router. Sicherstellung der Internet- und Netzwerkstabilität.
*   **Phase 2 (Erweiterung auf 32 GB RAM):** Hinzufügen der VMs für Dockploy und Seafile sowie Einrichtung des Ingress-Routings.

#### 2. Hardware-Spezifikationen & Storage-Setup
*   **CPU:** Intel Core i5-6600K (4 Kerne, 4 Threads, unterstützt AES-NI).
*   **RAM:** Aktuell 16 GB DDR4. Ein Upgrade auf 32 GB ist fest eingeplant.
*   **Netzwerk (Physisch):**
    *   1x Onboard LAN-Port (Mainboard).
    *   1x PCIe-Netzwerkkarte (10Gtek Intel I350-T2, Dual-Port, 1 GbE).
*   **Speicher (OS & VMs - SSDs):** 
    *   1x 250 GB SSD und 1x 500 GB SSD werden bei der Proxmox-Installation als **ZFS Mirror (RAID 1)** konfiguriert. Der nutzbare Speicher beträgt initial 250 GB. Sobald die 250 GB SSD später durch eine 500 GB SSD ersetzt wird, wird der Pool per Resilvering und `autoexpand=on` auf 500 GB vergrößert.
    *   1x 125 GB SSD bleibt vorerst ungenutzt und wird später als dediziertes lokales Backup-Laufwerk eingebunden.
*   **Speicher (Daten - HDDs):** 3x 2 TB HDDs (3,5 Zoll).
*   **Infrastruktur:** Telekom VDSL 50 Mbit/s (später Glasfaser). Ein Modem (Speedport im Modem-Modus) wird vor den Server geschaltet. Ein unmanaged Switch verteilt das LAN im Haus.

#### 3. Netzwerk-Topologie & Physische Verkabelung
Das Netzwerk-Routing wird über Linux Bridges in Proxmox gelöst. Es gilt das "Emergency Backdoor"-Konzept zur Absicherung des Management-Zugriffs:
*   **WAN (`vmbr1`):** Port 1 der PCIe-Karte. Physisch mit dem Modem verbunden. Proxmox hat hier *keine* IP. Wird an OPNsense für PPPoE durchgereicht.
*   **LAN (`vmbr0`):** Port 2 der PCIe-Karte. Physisch mit dem Switch verbunden. Proxmox bezieht hier seine **Haupt-Management-IP** (z. B. 192.168.1.10). OPNsense fungiert hier als Gateway (192.168.1.1) und DHCP-Server.
*   **Notfall-Port (`vmbr2`):** Onboard LAN-Port. Bleibt **physisch leer**. Erhält eine statische IP aus einem isolierten Netz (z. B. 10.99.99.1). Dient dem direkten Laptop-Zugriff, falls OPNsense oder der Switch ausfallen.
*   **DMZ (`vmbr3`):** Virtuelle Brücke *ohne* physischen Port. Proxmox hat hier *keine* IP. Hier befinden sich die Dockploy-VM und die Seafile-VM. Jeglicher Traffic zwischen DMZ und LAN muss die OPNsense-Firewall passieren.

#### 4. Virtuelle Maschinen & Ressourcen-Zuteilung
Es wird **kein CPU-Pinning** verwendet. Die Priorisierung erfolgt über Proxmox CPU Units (Weights), um die 4 physischen Kerne optimal auszulasten.

*   **VM 1: OPNsense (Router & Firewall)**
    *   **CPU:** 2 vCores. **Priorität (CPU Weight): 4096** (Realtime-Priorität für Routing).
    *   **RAM:** 2 GB.
    *   **Aufgabe:** PPPoE-Einwahl, DHCP, Firewall, Ingress-Routing (Layer 4).
*   **VM 2: Dockploy (Public Apps)**
    *   **CPU:** 4 vCores. Priorität: 1024 (Standard).
    *   **RAM:** 6 GB (in Phase 1) $\rightarrow$ 14 GB (in Phase 2).
    *   **Aufgabe:** Docker-Host, Traefik, Supabase (pgvector). Befindet sich in der DMZ.
*   **VM 3: Seafile (Private Storage / Cloud)**
    *   **CPU:** 2 vCores. Priorität: 1024 (Standard).
    *   **RAM:** 4 GB (in Phase 1) $\rightarrow$ 8 GB (in Phase 2).
    *   **Aufgabe:** Cloud-Speicher für Freunde (öffentlich erreichbar ohne VPN). Befindet sich zwingend in der DMZ.

#### 5. Ingress, Routing & SSL-Konzept
*   **Domain:** Eine `.de`-Domain (z. B. `dustinwalker.de`) ist vorhanden. DynDNS läuft über OPNsense.
*   **SSL Passthrough (Layer 4 Routing):** OPNsense nimmt den HTTPS-Traffic (Port 443) an, macht aber **keine** SSL-Termination. OPNsense nutzt SNI-Routing (z. B. via HAProxy-Plugin):
    *   Regel 1: Traffic für `cloud.dustinwalker.de` wird verschlüsselt an die Seafile-VM weitergeleitet.
    *   Regel 2 (Wildcard): Traffic für `*.dustinwalker.de` wird verschlüsselt an die Dockploy-VM weitergeleitet.
*   **SSL-Termination:** Wird von den Endpunkten selbst übernommen. Traefik (in Dockploy) und Seafile beziehen und verwalten ihre eigenen Let's Encrypt Zertifikate.

#### 6. Storage-Konfiguration (ZFS) & Backup
*   **ZFS-Pool (HDDs):** Die 3x 2 TB HDDs werden im Proxmox-Host als **RAIDZ1** konfiguriert (ca. 3,5 TB nutzbar).
*   **Zuweisung:** Auf dem RAIDZ1-Pool wird eine virtuelle Festplatte (`.raw`) erstellt und an die Seafile-VM durchgereicht.
*   **ZFS-Tuning:**
    *   ZFS ARC (RAM-Cache) wird in Proxmox hart limitiert: **Max. 2 GB in Phase 1**, max. 4 GB in Phase 2.
    *   Kompression (LZ4/ZSTD) ist aktiviert. Deduplizierung ist strikt deaktiviert.
    *   `sync=standard` bleibt aktiviert (Schutz vor Datenverlust, da keine USV vorhanden).
    *   Kein HDD-Spindown (Standby), um die Mechanik bei ZFS-Nutzung zu schonen.
*   **Backup:** Automatisierte ZFS-Snapshots der Seafile-VM auf dem Proxmox-Host (z. B. via `sanoid`). Später Einrichtung von VM-Backups auf die dedizierte 125 GB SSD.
