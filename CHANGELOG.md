# Changelog

## 1.8.2 – 2026-11-09
- RDS-Optimierung: Erkennungskarte „Office“ – Produkt (Click-to-Run oder MSI), Version, Kanal, Lizenzart (Microsoft 365 / Volumenlizenz / Retail mit Warnung) und Status Shared Computer Activation
- Neuer Punkt „Microsoft 365 Apps: Shared Computer Activation“ (Gruppe Office; nur Microsoft 365 auf RD-Sitzungshost oder PVS-/MCS-Image): setzt `SharedComputerLicensing` in der Click-to-Run-Konfiguration und als Richtlinie, rückgängig machbar
- Versiegeln: Fehlt SCA bei Microsoft 365 Apps, fragt das Tool nach und setzt sie; Warnung im Versiegeln-Text bei fehlender SCA oder Retail-Lizenz
- Neuer Versiegeln-Schritt „Microsoft-365-Lizenzreste entfernen“: Licensing-/Licenses-Ordner und Office-Identität des Admins, Abonnement-/Grace-Produktschlüssel (`ospp.vbs /unpkey`); Volumenschlüssel bleiben

## 1.8.1 – 2026-11-09
- RDS-Optimierung, Gruppe „Cache-Laufwerk“: neuer Punkt „Cache-Laufwerk bei jedem Start vorbereiten“ – geplante Aufgabe `\WindowsOptimizer\Cache-Laufwerk vorbereiten` (beim Start, SYSTEM) legt auf der leeren Cache-Platte neuer PVS-/MCS-Maschinen fehlende Ordner für Ereignisprotokolle, Spooler und WEM-Cache mit Rechten an und startet die betroffenen Dienste neu (kein Formatieren; Vorbild BIS-F-Personalisierung). Skript und Protokoll unter `%ProgramData%\WindowsOptimizer` (nur SYSTEM/Administratoren schreibberechtigt); rückgängig entfernt Aufgabe und Skript
- Hinweis, wenn ein CD/DVD-Laufwerk vorhanden ist (kann in Klonen den Cache-Buchstaben belegen)
- Text der Ereignisprotokoll-Umleitung korrigiert: Überstehen des Neustarts nur bei PVS, MCSIO-Cache wird standardmäßig zurückgesetzt
- Versiegeln: Hinweis „kein Sysprep“ auf PVS-/MCS-Systemen

## 1.8.0 – 2026-11-08
- Neue Seite „Windows Update“: verfügbare Updates (Kategorie, Schweregrad, Größe), Installation ausgewählter bzw. wichtiger Updates (ohne Treiber/optionale) im Hintergrund mit Fortschritt und Abbrechen, Neustart-Angebot; Update-Verlauf ohne Store-Apps plus Hotfixes, Fehlertexte zu gängigen Fehlercodes
- CVE-Prüfung auf Knopfdruck über den Microsoft Security Update Guide: offene Sicherheitslücken des installierten Builds mit Titel, Schweregrad, CVSS, „ausgenutzt“, behebender KB und Verfügbarkeit; Zusammenfassung je KB; Warnung bei nicht mehr unterstützter Version (bzw. Windows 10 nur mit ESU)
- Systemabhängig: Produktname für Windows 10/11 (x64/ARM64/32-Bit), Server 2016–2025 und Server Core; Update-Quelle (Windows Update, Microsoft Update, WSUS) und Dienststatus werden angezeigt
- Suche, Installation und CVE-Abgleich laufen als eigene PowerShell-Prozesse, die Oberfläche bleibt bedienbar

## 1.7.0 – 2026-11-08
- Neue Seite „Windows-Tweaks“: 44 Tweaks für das laufende System (davon 5 gemeinsam mit der RDS-Optimierung) (Datenschutz & Werbung, Leistung, Explorer & Bedienung, System & Netzwerk) mit Erklärung, Filter nach Bereich, einzeln anwenden und rückgängig machen; Erkennung von Windows 10/11/Server, Version, Gerät (Notebook/VM) und Edge
- Geltungsbereich der Benutzer-Tweaks wählbar: aktueller Benutzer (auch ohne Adminrechte) / zusätzlich Standardprofil für neue Benutzer / nur rechnerweit
- Einmalige Aktionen (nicht umkehrbar, mit Warnung): Temp-Dateien, Update-Downloadcache, DISM-Komponentenbereinigung, Widgets-/Copilot-App entfernen, OneDrive deinstallieren
- Vor dem Anwenden auf Windows 10/11 Wiederherstellungspunkt; `.reg`-Export `tweaks_<Datum>.reg`; Explorer-Neustart der eigenen Sitzung auf Nachfrage
- Rückgängig entfernt nun auch Registry-Schlüssel, die beim Anwenden neu angelegt wurden (wenn leer) – gilt auch für die RDS-Optimierung
- Fehler behoben: Registry-Werte vom Typ Binär und Mehrfachzeichenfolge ließen sich nicht schreiben bzw. wiederherstellen

## 1.6.2 – 2026-11-07
- Seite „Software“: Fortschrittsbalken über der Liste während der Updates – Gesamtfortschritt (Paket x/y) und aktuelles Paket (Prozent aus der winget-Ausgabe, sonst laufende Anzeige)

## 1.6.1 – 2026-11-06
- RDS-Optimierung: „Deaktivierbar“-Dienste sind nur noch vorausgewählt („Empfohlen“), wenn sie auf einem RDS-Host sicher ungenutzt sind (fehlende VM-Hardware, Consumer-/Spielefunktionen – 67 von 102 Regeln). Die übrigen 35 erscheinen als „Prüfen“ mit Grund im Detailtext (z. B. Intune/MDM, WSD-Drucker, WSL, Windows Hello, IE-ActiveX). Einstufung auf der Seite „Dienste“ unverändert.

## 1.6.0 – 2026-11-06
- Neue Seite **„Software“**: installierte Software mit Update-Prüfung über `winget list` (Name, ID, Version, verfügbare Version, Quelle); ohne winget Liste aus der Registry (ohne Update-Prüfung)
- Aktualisieren über `winget upgrade --id … --exact --silent` für **ausgewählte** Pakete oder **alle Updates** (nur Quelle winget mit bekannter Version); läuft im Hintergrund Paket für Paket, mit Fortschritt, „Abbrechen“ nach dem aktuellen Paket, Ergebnis/Fehlercode je Paket (Tooltip und Protokoll), danach erneute Prüfung
- winget-Ausgabedatei wird mit geteiltem Zugriff gelesen (Installer bzw. neu gestartete Programme erben das Datei-Handle und hielten sie gesperrt → Fehler „Datei wird von einem anderen Prozess verwendet“); Rückruf läuft auch bei Lesefehlern, Reste werden beim nächsten Lauf aufgeräumt
- Anzahl im Protokoll bei nur einem Paket korrigiert („Start:  Update(s)“)

## 1.5.0 – 2026-11-06
- Neue Seite **„Startmenü“**: zeigt alle Einträge des gemeinsamen Startmenüs (ProgramData) mit Ziel, Ordner und Sichtbarkeit sowie Store-Apps (nur Anzeige)
- Je Eintrag (Mehrfachauswahl): **für alle sichtbar**, **ausblenden** (Verschieben in die Ablage `C:\ProgramData\WindowsOptimizer\StartMenuHidden`, außerhalb des Startmenüs) oder **nur für Gruppen** (geschützte NTFS-Rechte: SYSTEM, Administratoren, gewählte Gruppen; Gruppennamen werden vorab geprüft)
- Ursprüngliche Rechte je Verknüpfung in `backups\startmenu_original.json`; „Für alle sichtbar“ stellt sie exakt wieder her

## 1.4.1 – 2026-11-06
- „Versiegeln und herunterfahren“: neuer Schritt **Office-Lizenz zurücksetzen (ospprearm)** bei jedem Versiegeln – nur bei Office-Volumenlizenz (KMS/MAK, auch LTSC Click-to-Run, erkannt über `ospp.vbs /dstatus`); Microsoft 365 bzw. fehlendes Office werden mit Grund übersprungen. Lizenzstatus nach dem Rearm im Protokoll. Kein Windows-Rearm.
- Versiegeln-Schritte können eine eigene Prüfung (`Check`) mit Begründung fürs Überspringen haben

## 1.4.0 – 2026-11-06
Ergänzungen nach Analyse von BIS-F 7.1912.7 (nur Einstellungen/Erkennungsmerkmale übernommen, kein Code – BIS-F ist GPL-3.0):
- **Erkennung korrigiert**: `Personality.ini` kennzeichnet MCS (`DiskMode`), nicht PVS. PVS-Modus kommt jetzt aus `bnistack\PVSAgent\WriteCacheType` (0/10 = Schreibzugriff), Wartungsversion über `.avhd(x)`. Neu: VDA-Version, MCSIO (ab VDA 7.21), WEM-Cache-Ort, Plattform-Karte (Hersteller/Modell, VMware), Server 2019
- **Neue umkehrbare Punkte**: Netzwerkdialog aus, UDP FastSend, BFE MaxEndpointCountMult, IPv6 aus, RSS aus, Boot-Statusrichtlinie, PVS-Statussymbol, Server 2019 FastReconnect, VMware-Tools-Symbol, vmdebug
- **Cache-Laufwerk**: Ereignisprotokolle, Druckspooler, Auslagerungsdatei und WEM-Agent-Cache auf das persistente Laufwerk umleiten (Auswahl auf der Seite, rückgängig je Punkt)
- **Button „Versiegeln und herunterfahren“**: führt nach einer Image-Aktualisierung alle einmaligen, nicht umkehrbaren Schritte gesammelt aus (vorher Liste mit Rückfrage, übersprungene Schritte mit Grund) und fährt herunter; diese Schritte stehen nicht mehr in der Optimierungsliste. Schritte: WSUS-Kennung, Update-Downloadcache, DNS/ARP-Cache, Ereignisprotokolle leeren, DirtyShutdown, Citrix-Cache, MSDTC, Leistungsindikatoren, RDS-Kulanzfrist zurücksetzen (nur RD-Sitzungshost; Besitzer/Rechte des Schlüssels werden wiederhergestellt)
- Fehler behoben: Punkte mit nur einem Registry-Wert wurden nie als „Umgesetzt“, sondern als „Teilweise“ angezeigt

## 1.3.0 – 2026-11-06
- Neue Seite **„RDS-Optimierung“**: erkennt Citrix VDA, WEM-Agent, PVS-Target-Device (inkl. vDisk-Modus aus `Personality.ini`) und MCS
- ~35 Optimierungen (Registry, geplante Aufgaben, Dienste, Ruhezustand/Energieplan) plus alle als „Deaktivierbar“ eingestuften Dienste; Gruppen Allgemein / PVS/MCS / PVS / MCS / WEM / Dienste, Stufe Empfohlen / Prüfen / Hinweis
- Einzeln auswählbar, Empfohlene vorausgewählt; Anwenden und **Rückgängig je Punkt** (Originalzustand in `backups\rdsopt_original.json`), `.reg`-Export vor dem Anwenden, Warnung bei PVS-Standard-Modus
- `Export-RegBackup` nimmt optional eine eigene Schlüsselliste

## 1.2.0 – 2026-11-06
- Umbenannt in **Windows-Optimizer** (`Start-WindowsOptimizer.cmd`, `WindowsOptimizer.ps1`); Sicherungen des Autostart-Managers bleiben lesbar
- Autostart deaktivieren verschiebt den Eintrag jetzt in die Ablage `WindowsOptimizerDisabled` (Run-Unterschlüssel bzw. Startordner-Unterordner) statt nur StartupApproved zu setzen – wirkt zuverlässig
- Einträge mit alter Task-Manager-Sperre werden markiert; Button „Endgültig deaktivieren“ stellt sie um
- Eigenes App-Symbol (Tachometer) in Fenster, Seitenleiste und Taskleiste (eigene Taskleistengruppe statt PowerShell)
- Statusmeldung und Tooltip „Quelle“ zeigen Eintrags- bzw. Ablageort

## 1.1.0 – 2026-11-06
- Neue Seite „Dienste“: Windows-Dienste mit Suche, Filter (Automatisch/Manuell/Deaktiviert), Starttyp änderbar per Auswahl (sc.exe)
- Spalte „Citrix RDS“: Einstufung Benötigt / Belassen / Prüfen / Deaktivierbar / Drittanbieter mit Begründung (~300 Regeln nach Citrix Optimizer, Microsoft WDOT und Microsoft-Dienstempfehlungen; unbekannte Dienste per Hersteller/Programmdatei eingeordnet); Rückfrage beim Deaktivieren benötigter Dienste
- Sicherung Format-Version 2: enthält zusätzlich Dienst-Starttypen; Wiederherstellung setzt sie zurück (v1-Sicherungen weiter nutzbar)
- README.md mit Funktionsbeschreibung und Bedienungsanleitung

## 1.0.0 – 2026-11-04
- Erste Version: Autostart-Manager als portables PowerShell/WPF-Tool
- Autostart-Liste mit Suche, Filter, Schalter je Eintrag, „Anzeigen“ im Explorer
- Systeminformationen, Sicherung/Wiederherstellung, Protokoll
