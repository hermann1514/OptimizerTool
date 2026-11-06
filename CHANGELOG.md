# Changelog

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
