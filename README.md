# Windows-Optimizer

Ein kleines, portables Windows-Werkzeug, das alle Programme anzeigt, die bei der Anmeldung automatisch starten, und die Windows-Dienste mit ihrem Starttyp. Jedes Autostart-Programm lässt sich einzeln aus- und wieder einschalten, jeder Dienst lässt sich umstellen.
Dazu kommen eine Übersicht der Systeminformationen, eine Sicherung mit Wiederherstellung und ein Protokoll aller Änderungen.

**Keine Installation nötig.** Das Tool nutzt nur PowerShell und WPF, beides ist in Windows bereits enthalten.

---

## Funktionen

- **Autostart-Liste**: zeigt Programme aus folgenden Quellen:
  - Registry `Run` des aktuellen Benutzers (HKCU)
  - Registry `Run` für alle Benutzer (HKLM, auch 32-Bit)
  - Autostart-Ordner des Benutzers und für alle Benutzer
- **Ein-/Ausschalten pro Programm** per Schalter. Ausgeschaltete Einträge werden in einen Ablagebereich verschoben, den Windows nicht ausführt. Es wird nichts gelöscht.
- **Alte Task-Manager-Sperren erkennen**: Einträge, die nur im Task-Manager deaktiviert sind (und deshalb manchmal trotzdem starten), werden markiert und lassen sich mit einem Klick endgültig abschalten.
- **Zusatzinfos je Eintrag**: Herausgeber, Programmbeschreibung, vollständiger Befehl, Quelle, Hinweis *„Datei fehlt“* bei verwaisten Einträgen.
- **Suche und Filter** (Alle / Aktiv / Deaktiviert), Sortierung per Klick auf die Spaltenköpfe.
- **„Anzeigen“** öffnet den Speicherort der Programmdatei im Explorer.
- **Windows-Dienste**: Starttyp ändern (Automatisch / Automatisch (verzögert) / Manuell / Deaktiviert), mit Einschätzung, ob der Dienst auf einem **Citrix-RDS-Host** benötigt wird.
- **RDS-Optimierung**: erkennt Citrix VDA, **WEM-Agent**, **PVS-Target-Device** und **MCS** und schlägt passende Optimierungen vor (Registry, geplante Aufgaben, Dienste, Energieplan/Ruhezustand). Jeder Punkt lässt sich einzeln auswählen, anwenden und wieder **rückgängig** machen.
- **Systeminformationen**: Betriebssystem, Rechner/BIOS, Prozessor, Arbeitsspeicher, Grafik, Datenträger, Netzwerk. Mit einem Klick als Text kopierbar.
- **Sicherung und Wiederherstellung** von Autostart-Zustand und Dienst-Starttypen, mit Vorschau vor dem Zurückspielen.
- **Protokoll**: jede Änderung mit Zeitpunkt, eine Datei pro Tag.

## Voraussetzungen

- Windows 10/11 oder Windows Server 2016 und neuer
- Windows PowerShell 5.1 (ab Werk vorhanden)
- Für Einträge *aller Benutzer* (HKLM) und für Dienste: Administratorrechte

## Start

1. Projekt herunterladen: auf GitHub über **Code → Download ZIP**, oder per Git:
   ```
   git clone https://github.com/hermann1514/OptimizerTool.git
   ```
2. Bei einer ZIP-Datei: vor dem Entpacken **Rechtsklick → Eigenschaften → „Zulassen“** anhaken. Sonst warnt Windows beim Start, weil die Datei aus dem Internet stammt.
3. **`Start-WindowsOptimizer.cmd`** doppelklicken.

Der Ordner kann überall liegen, auch auf einem USB-Stick. Die Dateien `Start-WindowsOptimizer.cmd`, `WindowsOptimizer.ps1` und `MainWindow.xaml` müssen im selben Ordner bleiben.
Das Tool erscheint mit eigenem Symbol in der Taskleiste (nicht als PowerShell).

## Bedienung

### Autostart

| Element | Bedeutung |
|---|---|
| Schalter links | an = startet bei der Anmeldung, aus = in die Ablage verschoben, startet nicht mehr |
| Ausgegrauter Schalter | Eintrag für alle Benutzer, nur mit Adminrechten änderbar |
| *nur Task-Manager-Sperre* | Eintrag ist nur im Task-Manager deaktiviert – manche Programme starten trotzdem. Der gelbe Hinweis oben bietet **„Endgültig deaktivieren“** für alle diese Einträge. |
| Quelle | Woher der Eintrag stammt (`HKCU Run`, `HKLM Run`, `Startordner` …). Beim Darüberfahren erscheint der genaue Pfad bzw. der Ablageort. |
| Datei fehlt | Die Programmdatei existiert nicht mehr, der Eintrag ist vermutlich ein Überbleibsel |
| Neu einlesen | Liste aktualisieren, z. B. nach einer Programminstallation |

Änderungen gelten ab der **nächsten Anmeldung**. Bereits laufende Programme werden nicht beendet.

### Dienste

| Element | Bedeutung |
|---|---|
| Starttyp | Auswahl Automatisch / Automatisch (verzögert) / Manuell / Deaktiviert. Wird sofort per `sc.exe config` gesetzt. Nur mit Adminrechten änderbar. |
| Status | Läuft / Beendet. Der Dienst wird beim Ändern des Starttyps **nicht** gestartet oder gestoppt. |
| Citrix RDS | **Benötigt** (nicht deaktivieren), **Belassen** (Windows-Bestandteil, Ändern bringt nichts), **Prüfen** (abhängig vom Einsatz, z. B. MCS/PVS, Smartcard, Webcam, Updates), **Deaktivierbar** (auf RDS-Hosts üblicherweise abgeschaltet), **Drittanbieter** (Dienst installierter Software, Hersteller im Tooltip). Die Begründung erscheint beim Darüberfahren. |

Die Einstufung ist eine allgemeine Empfehlung (rund 300 Regeln nach Citrix Optimizer, Microsoft Windows Desktop Optimization Tool und den Microsoft-Dienstempfehlungen für Windows Server), keine verbindliche Vorgabe. Wo Microsoft für reine Server „deaktivierbar“ sagt, ein RDS-Host den Dienst aber braucht (z. B. Audio, Druck), ist für RDS eingestuft und im Tooltip vermerkt. Dienste ohne Regel werden über Programmdatei und Hersteller eingeordnet. Wer einen als „Benötigt“ eingestuften Dienst deaktivieren will, muss das bestätigen.
Benutzerdienst-Instanzen (Name mit Suffix, z. B. `CDPUserSvc_1a2b3`) sind nicht änderbar; ihr Starttyp kommt von der Vorlage. Geschützte Dienste (z. B. Defender) lehnt Windows ab – das Tool meldet das.

### RDS-Optimierung

Oben zeigen fünf Karten, was erkannt wurde: **Citrix VDA** (mit Version), **WEM-Agent** (mit Cache-Ort), **PVS-Target** (installiert bzw. von vDisk gestartet, Schreibcache-Typ, Wartungsversion), **MCS** (installiert bzw. bereitgestellt mit DiskMode, MCSIO ab VDA 1903) und **Plattform** (Hersteller/Modell, VMware, Windows-Build). Erkannt wird anhand von Diensten/Treibern und Registry-Schlüsseln – also auch im Master-Image, bevor es verteilt wird.

| Bereich | Beispiele |
|---|---|
| Allgemein | Telemetrie minimal, Consumer-Features/Tipps aus, Erstanmelde-Animation aus, Hintergrund-Apps aus, geplante Aufgaben (Defrag, CEIP, Kompatibilitäts-Telemetrie, Karten …), Ruhezustand aus, Energieplan Höchstleistung, NTFS-Zeitstempel „Letzter Zugriff“ aus |
| PVS/MCS | Automatische Wartung, Prefetch/Superfetch, Boot-Optimierung, SysMain, Offlinedateien, Registry-Leerlaufsicherung, Wiederherstellungspunkte; Windows Update nur als „Prüfen“ |
| PVS | TCP Task Offload aus, Kennwortänderung des Computerkontos aus (PVS verwaltet das Kennwort) |
| MCS | Hinweis: Kennwortänderung **nicht** sperren (regelt der Machine Identity Service) |
| WEM | Agent-Dienst automatisch; bei PVS/MCS `AgentServiceUseNonPersistentCompliantHistory`; Hinweise zu Agent-Cache und doppelten Optimierungen |
| Dienste | alle installierten Dienste, die auf der Seite „Dienste“ als *Deaktivierbar* eingestuft sind |
| Netzwerk (Prüfen) | UDP FastSend 1500, BFE MaxEndpointCountMult, IPv6 aus, RSS aus; „Neues Netzwerk“-Dialog aus (Empfohlen) |
| Citrix / VMware | PVS-Statussymbol aus, Server 2019 FastReconnect aus, VMware-Tools-Symbol aus, vmdebug aus |
| Cache-Laufwerk | Ereignisprotokolle, Druckspooler, Auslagerungsdatei und WEM-Agent-Cache auf das persistente Laufwerk (PVS-Schreibcache bzw. MCSIO). Laufwerk oben auf der Seite wählen. |

**Versiegeln und herunterfahren** (Button oben rechts, nur mit Adminrechten): Nach jeder Image-Aktualisierung führt er alle einmaligen, nicht umkehrbaren Schritte aus und fährt den Rechner dann herunter. Vorher listet eine Rückfrage auf, welche Schritte ausgeführt und welche (mit Grund) übersprungen werden:
WSUS-Kennung entfernen, Update-Downloadcache leeren, DNS/ARP-Cache leeren, Ereignisprotokolle leeren, Markierung „unerwartet heruntergefahren“ entfernen, Citrix-Cache leeren (nur VDA), MSDTC zurücksetzen, RDS-Kulanzfrist zurücksetzen (nur RD-Sitzungshost; ersetzt keine RDS-CALs), Leistungsindikatoren neu aufbauen.
Vorher wird automatisch gesichert; schlägt ein Schritt fehl, fragt das Tool vor dem Herunterfahren nach. Neben dem Button steht der Zeitpunkt des letzten Versiegelns.

Mehrere Ergänzungen stammen aus der Analyse von **BIS-F** (Base Image Script Framework, GPL-3.0); übernommen wurden nur Einstellungen und Erkennungsmerkmale, kein Code.

- **Empfehlung**: *Empfohlen* (beim Laden vorausgewählt, wenn noch offen), *Prüfen* (vom Einsatz abhängig, nicht vorausgewählt), *Hinweis* (wird nicht automatisch gesetzt).
- **Status**: Umgesetzt / Teilweise / Offen / Nicht zutreffend (Komponente nicht erkannt) / Nicht vorhanden.
- **Anwenden**: Rückfrage mit Liste, dann automatische Sicherung, `.reg`-Export der betroffenen Schlüssel (`backups\rdsopt_<Datum>.reg`) und Umsetzung Punkt für Punkt.
- **Rückgängig**: Beim ersten Anwenden wird der ursprüngliche Zustand je Punkt in `backups\rdsopt_original.json` gespeichert (auch „Wert fehlte“). „Rückgängig“ stellt genau diesen Zustand wieder her – auch nach einem Neustart des Tools.
- Läuft eine PVS-vDisk im **Standard-Modus**, erscheint eine Warnung: Änderungen gehen beim Neustart verloren, daher im Wartungsmodus bzw. Master-Image optimieren.
- Viele Einstellungen wirken erst nach einem **Neustart**. Nur mit Adminrechten.

### Administratorrechte

Ohne Adminrechte werden alle Einträge angezeigt, aber nur die des eigenen Benutzers lassen sich schalten; Dienste sind gesperrt.
Über **„Als Administrator starten“** unten in der Seitenleiste startet das Tool neu mit erhöhten Rechten.

### System

Zeigt die wichtigsten Daten des Rechners. Füllbalken zeigen die Belegung von RAM, Datenträgern und Prozessor. Ab 75 % werden sie orange, ab 90 % rot.
**„Als Text kopieren“** legt alles in die Zwischenablage, z. B. für eine Support-Anfrage.

### Sicherung

- **Sicherung erstellen**: speichert, welche Einträge gerade aktiv oder deaktiviert sind, und den Starttyp aller Dienste.
- **Wiederherstellen**: setzt den Zustand einer ausgewählten Sicherung zurück. Vorher erscheint eine Liste der geplanten Änderungen zur Bestätigung. Einträge, die seit der Sicherung gelöscht wurden, werden wieder angelegt, soweit möglich. Neu hinzugekommene Einträge bleiben unverändert.
- **Löschen**: entfernt die ausgewählte Sicherung.

Automatische Sicherungen entstehen
- vor der **ersten Änderung** in jeder Sitzung und
- vor jeder **Wiederherstellung**.

Zu jeder Sicherung gibt es zusätzlich eine `.reg`-Datei mit den Run-Schlüsseln (inklusive Ablage) und StartupApproved. Im Notfall lässt sie sich auch ohne das Tool per Doppelklick einspielen.
Sicherungen des Vorgängers *Autostart-Manager* bleiben lesbar.

### Protokoll

Zeigt alle Aktionen des gewählten Tages, die neueste steht oben. Ein Beispiel:

```
2026-11-06 14:02:11  INFO   SICHERUNG   autostart_20261106_140210.json (21 Einträge, 210 Dienste, Anlass: Automatisch (vor erster Änderung))
2026-11-06 14:02:11  INFO   DEAKTIVIERT OneDrive  [HKCU Run, in Ablage verschoben]  "C:\Program Files\Microsoft OneDrive\OneDrive.exe" /background
```

## So funktioniert das Ausschalten

Beim Ausschalten wird der Eintrag **verschoben**, nicht gelöscht (gleiches Prinzip wie Sysinternals Autoruns):

| Quelle | Ablage |
|---|---|
| `…\CurrentVersion\Run` (HKCU, HKLM, WOW6432Node) | Unterschlüssel `…\CurrentVersion\Run\WindowsOptimizerDisabled` |
| Autostart-Ordner (Benutzer, alle) | Unterordner `…\Startup\WindowsOptimizerDisabled` |

Windows wertet weder Unterschlüssel von `Run` noch Unterordner des Autostart-Ordners aus – der Eintrag startet also sicher nicht mehr. Einschalten schreibt ihn unverändert zurück (gleicher Name, Typ und Befehl).

- Ausschalten lässt sich jederzeit rückgängig machen.
- Der Task-Manager zeigt ausgeschaltete Einträge nicht mehr an (sie stehen ja nicht mehr in `Run`).
- Trägt sich ein Programm beim nächsten Start selbst wieder in `Run` ein (z. B. Browser oder Messenger mit eigener Option „Mit Windows starten“), erscheint es wieder als aktiv. Dann die Autostart-Option im Programm selbst abschalten.
- Eine Sperre aus dem Task-Manager (`…\Explorer\StartupApproved`) wird beim Einschalten automatisch aufgehoben.

## Speicherorte

| Daten | Ort |
|---|---|
| Sicherungen | `backups\` neben dem Skript |
| Protokolle | `logs\` neben dem Skript |

Ist der Programmordner schreibgeschützt (z. B. unter `C:\Programme`), verwendet das Tool stattdessen `%LOCALAPPDATA%\WindowsOptimizer\`.

## Dateien

| Datei | Zweck |
|---|---|
| `Start-WindowsOptimizer.cmd` | Starter (Doppelklick) |
| `WindowsOptimizer.ps1` | Programmlogik |
| `MainWindow.xaml` | Oberfläche |

## Grenzen

- Geplante Aufgaben werden nur auf der Seite „RDS-Optimierung“ (feste Liste) behandelt, nicht allgemein angezeigt.
- Die Erkennung von WEM/PVS/MCS ist heuristisch (Dienst-/Treibernamen, Registry); auf echten Citrix-Systemen gegenprüfen.
- Die `.reg`-Datei einer Sicherung enthält nur Registry-Schlüssel, nicht die Dienste (Dienst-Starttypen stehen in der `.json`-Sicherung) und nicht die Dateien im Autostart-Ordner.
- Dateien im Autostart-Ordner, die keine Verknüpfung (`.lnk`) sind, kann die Wiederherstellung nicht neu erzeugen, wenn sie gelöscht wurden. Ihr An/Aus-Zustand wird trotzdem wiederhergestellt.
- Wer den Admin-Neustart mit einem **anderen** Administratorkonto bestätigt, sieht unter „Benutzer“ dessen Einträge statt der eigenen.

## Fehlerbehebung

| Problem | Lösung |
|---|---|
| Doppelklick auf die `.cmd` tut nichts | Prüfen, ob alle drei Dateien im selben Ordner liegen; ZIP vorher „zulassen“ (siehe *Start*) |
| Umlaute werden falsch angezeigt | `WindowsOptimizer.ps1` muss als **UTF-8 mit BOM** gespeichert sein |
| Schalter lässt sich nicht bewegen | Eintrag gehört zu „Alle Benutzer“: **Als Administrator starten** |
| Fehlermeldung beim Start | Details stehen im Protokoll unter `logs\` |
| Ausgeschaltetes Programm ist wieder aktiv | Das Programm hat sich selbst neu eingetragen. Autostart-Option im Programm abschalten und erneut ausschalten. |
| Ausgeschalteten Eintrag manuell finden | Registry: `…\CurrentVersion\Run\WindowsOptimizerDisabled`; Ordner: `shell:startup\WindowsOptimizerDisabled` |
