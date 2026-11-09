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
- **Windows-Tweaks**: bewährte Einstellungen für das laufende Windows (Datenschutz & Werbung, Leistung, Explorer & Bedienung, System & Netzwerk) mit Erklärung, einzeln anwendbar und **rückgängig**; dazu einmalige Aufräumaktionen. Benutzer-Tweaks wahlweise für den aktuellen Benutzer, zusätzlich das Standardprofil oder gar nicht.
- **RDS-Optimierung**: erkennt Citrix VDA, **WEM-Agent**, **PVS-Target-Device** und **MCS** und schlägt passende Optimierungen vor (Registry, geplante Aufgaben, Dienste, Energieplan/Ruhezustand). Jeder Punkt lässt sich einzeln auswählen, anwenden und wieder **rückgängig** machen.
- **Startmenü**: zeigt, was Benutzer auf dem RDS-Host im gemeinsamen Startmenü sehen, und legt je Eintrag fest: **für alle sichtbar**, **ausblenden** oder **nur für bestimmte Gruppen** (NTFS-Rechte). Store-Apps werden angezeigt.
- **Windows Update**: verfügbare und installierte Updates (Verlauf, Hotfixes), Installation im Hintergrund, und **offene Sicherheitslücken (CVEs)** des laufenden Systems mit dem Update, das sie behebt – abgeglichen mit dem Microsoft Security Update Guide.
- **Software**: listet die installierte Software, prüft per **winget** auf Updates und installiert sie – für ausgewählte Programme oder alle auf einmal.
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

### Windows-Tweaks

Oben zeigen Karten das erkannte System: **Betriebssystem** (Windows 10/11/Server, Version, Build, Edition), **Gerät** (Desktop, Notebook, VM, Server), **Computerschutz** (Wiederherstellungspunkte möglich?), **Benutzer** und **Rechte**. Angezeigt werden nur Tweaks, die zum System passen (z. B. Recall erst ab Windows 11 24H2, Edge-Punkte nur mit installiertem Edge). Erklärung je Punkt in der Zeile und im Tooltip.

| Bereich | Beispiele |
|---|---|
| Datenschutz & Werbung | Werbe-ID, Tipps/Vorschläge/stille App-Installationen, „Gerät fertig einrichten“, Werbung im Explorer, Bing in der Startsuche, Aktivitätsverlauf, Feedback-Anfragen, Standort (Prüfen), Copilot- und Recall-Richtlinie, Edge-Datenschutz (Prüfen), Telemetrie und Consumer-Features |
| Leistung | Visuelle Effekte (Prüfen), Game DVR, Autostart-Verzögerung (Prüfen), Übermittlungsoptimierung ohne Peers, svchost-Bündelung (Prüfen), Edge-Startboost/Hintergrundmodus, Speicheroptimierung (Prüfen), Hintergrund-Apps, Energieplan |
| Explorer & Bedienung | Dateiendungen anzeigen, versteckte Dateien, „Dieser PC“, klassisches Kontextmenü, Taskleiste links, Suche als Symbol, Widgets aus, Taskansicht, „Task beenden“, Num-Lock, Einrastfunktion |
| System & Netzwerk | Lange Pfade, ausführlicher Bluescreen/Anmeldestatus, WPBT, Gerätemetadaten, Schnellstart, SMB1, LLMNR, Teredo, Ruhezustand |
| Einmalige Aktionen | Temp-Dateien löschen, Update-Downloadcache leeren, Komponentenspeicher bereinigen (DISM, eigenes Fenster), Widgets-App / Copilot-App entfernen, OneDrive deinstallieren – **nicht umkehrbar**, nie vorausgewählt |

- **Benutzer-Tweaks gelten für** (Auswahl oben): *Aktueller Benutzer* (Art „Benutzer“, auch ohne Adminrechte änderbar), *Aktueller Benutzer + Standardprofil* (zusätzlich in `C:\Users\Default\NTUSER.DAT`, damit neue Benutzer die Einstellungen übernehmen; nur Admin) oder *Nur rechnerweite Einstellungen* (reine Benutzer-Tweaks entfallen).
- **Anwenden**: Rückfrage (Tweaks und einmalige Aktionen getrennt aufgelistet), automatische Sicherung, `.reg`-Export (`backups\tweaks_<Datum>.reg`), auf Windows 10/11 zusätzlich ein **Wiederherstellungspunkt** (wenn der Computerschutz an ist; Windows erlaubt höchstens einen pro 24 Stunden). Danach bietet das Tool bei Bedarf an, den Explorer der eigenen Sitzung neu zu starten.
- **Rückgängig** wie bei der RDS-Optimierung über `backups\rdsopt_original.json`. Beide Seiten teilen sich diese Ablage und die gemeinsamen Punkte (Telemetrie, Consumer-Features, Hintergrund-Apps, Energieplan, Ruhezustand).
- Bewusst nicht enthalten, weil umstritten oder wirkungslos: Auslagerungsdatei abschalten, Registry-Cleaner, IPv6 abschalten, Indexdienst abschalten, BitLocker aus.

### RDS-Optimierung

Oben zeigen fünf Karten, was erkannt wurde: **Citrix VDA** (mit Version), **WEM-Agent** (mit Cache-Ort), **PVS-Target** (installiert bzw. von vDisk gestartet, Schreibcache-Typ, Wartungsversion), **MCS** (installiert bzw. bereitgestellt mit DiskMode, MCSIO ab VDA 1903) und **Plattform** (Hersteller/Modell, VMware, Windows-Build). Erkannt wird anhand von Diensten/Treibern und Registry-Schlüsseln – also auch im Master-Image, bevor es verteilt wird.

| Bereich | Beispiele |
|---|---|
| Allgemein | Telemetrie minimal, Consumer-Features/Tipps aus, Erstanmelde-Animation aus, Hintergrund-Apps aus, geplante Aufgaben (Defrag, CEIP, Kompatibilitäts-Telemetrie, Karten …), Ruhezustand aus, Energieplan Höchstleistung, NTFS-Zeitstempel „Letzter Zugriff“ aus |
| PVS/MCS | Automatische Wartung, Prefetch/Superfetch, Boot-Optimierung, SysMain, Offlinedateien, Registry-Leerlaufsicherung, Wiederherstellungspunkte; Windows Update nur als „Prüfen“ |
| PVS | TCP Task Offload aus, Kennwortänderung des Computerkontos aus (PVS verwaltet das Kennwort) |
| MCS | Hinweis: Kennwortänderung **nicht** sperren (regelt der Machine Identity Service) |
| WEM | Agent-Dienst automatisch; bei PVS/MCS `AgentServiceUseNonPersistentCompliantHistory`; Hinweise zu Agent-Cache und doppelten Optimierungen |
| Dienste | alle installierten Dienste, die auf der Seite „Dienste“ als *Deaktivierbar* eingestuft sind. Vorausgewählt („Empfohlen“) nur, wenn sie auf einem RDS-Host sicher ungenutzt sind (fehlende VM-Hardware, Consumer-/Spielefunktionen); die übrigen stehen als „Prüfen“ mit Grund im Tooltip |
| Netzwerk (Prüfen) | UDP FastSend 1500, BFE MaxEndpointCountMult, IPv6 aus, RSS aus; „Neues Netzwerk“-Dialog aus (Empfohlen) |
| Citrix / VMware | PVS-Statussymbol aus, Server 2019 FastReconnect aus, VMware-Tools-Symbol aus, vmdebug aus |
| Cache-Laufwerk | Ereignisprotokolle, Druckspooler, Auslagerungsdatei und WEM-Agent-Cache auf das persistente Laufwerk (PVS-Schreibcache bzw. MCSIO). Laufwerk oben auf der Seite wählen. Eine Startaufgabe legt die Zielordner auf der leeren Cache-Platte neuer Maschinen an (formatiert wird von PVS/MCSIO). |

**Versiegeln und herunterfahren** (Button oben rechts, nur mit Adminrechten): Nach jeder Image-Aktualisierung führt er alle einmaligen, nicht umkehrbaren Schritte aus und fährt den Rechner dann herunter. Vorher listet eine Rückfrage auf, welche Schritte ausgeführt und welche (mit Grund) übersprungen werden:
WSUS-Kennung entfernen, Update-Downloadcache leeren, DNS/ARP-Cache leeren, Ereignisprotokolle leeren, Markierung „unerwartet heruntergefahren“ entfernen, Citrix-Cache leeren (nur VDA), MSDTC zurücksetzen, Office-Lizenz zurücksetzen (ospprearm, nur bei Office-Volumenlizenz KMS/MAK – nicht bei Microsoft 365), RDS-Kulanzfrist zurücksetzen (nur RD-Sitzungshost; ersetzt keine RDS-CALs), Leistungsindikatoren neu aufbauen.
Vorher wird automatisch gesichert; schlägt ein Schritt fehl, fragt das Tool vor dem Herunterfahren nach. Neben dem Button steht der Zeitpunkt des letzten Versiegelns.

Mehrere Ergänzungen stammen aus der Analyse von **BIS-F** (Base Image Script Framework, GPL-3.0); übernommen wurden nur Einstellungen und Erkennungsmerkmale, kein Code.

- **Empfehlung**: *Empfohlen* (beim Laden vorausgewählt, wenn noch offen), *Prüfen* (vom Einsatz abhängig, nicht vorausgewählt), *Hinweis* (wird nicht automatisch gesetzt).
- **Status**: Umgesetzt / Teilweise / Offen / Nicht zutreffend (Komponente nicht erkannt) / Nicht vorhanden.
- **Anwenden**: Rückfrage mit Liste, dann automatische Sicherung, `.reg`-Export der betroffenen Schlüssel (`backups\rdsopt_<Datum>.reg`) und Umsetzung Punkt für Punkt.
- **Rückgängig**: Beim ersten Anwenden wird der ursprüngliche Zustand je Punkt in `backups\rdsopt_original.json` gespeichert (auch „Wert fehlte“). „Rückgängig“ stellt genau diesen Zustand wieder her – auch nach einem Neustart des Tools.
- Läuft eine PVS-vDisk im **Standard-Modus**, erscheint eine Warnung: Änderungen gehen beim Neustart verloren, daher im Wartungsmodus bzw. Master-Image optimieren.
- Viele Einstellungen wirken erst nach einem **Neustart**. Nur mit Adminrechten.

### Startmenü

Listet alle Verknüpfungen aus dem gemeinsamen Startmenü (`C:\ProgramData\Microsoft\Windows\Start Menu\Programs`, inklusive Unterordnern) und die installierten Store-Apps.

| Spalte / Aktion | Bedeutung |
|---|---|
| Sichtbar für | **Alle** · **Ausgeblendet** (niemand sieht den Eintrag) · **Eingeschränkt** (nur die Gruppen in der Spalte „Gruppen“ und Administratoren) · **Store-App** (nur Anzeige) |
| Häkchen, „Angezeigte auswählen“ | Mehrere Einträge auswählen (berücksichtigt Suche und Filter) |
| Für alle sichtbar | Holt ausgeblendete Einträge zurück und stellt die ursprünglichen Rechte exakt wieder her |
| Ausblenden | Verschiebt die Verknüpfung nach `C:\ProgramData\WindowsOptimizer\StartMenuHidden` (außerhalb des Startmenüs) |
| Nur für Gruppen … | Fragt die Gruppen ab (z. B. `DOMÄNE\Buchhaltung, Remotedesktopbenutzer`), prüft die Namen und setzt die Rechte so, dass nur diese Gruppen und Administratoren die Verknüpfung lesen können |

Hinweise: Änderungen wirken ab der **nächsten Anmeldung**. Administratoren sehen immer alle Einträge. Software-Updates können Verknüpfungen neu anlegen – „Neu einlesen“ zeigt das. Ändern nur mit Adminrechten.

### Software

Liest die installierte Software über `winget list` (Name, ID, Version, verfügbare Version, Quelle). Ist winget nicht vorhanden (z. B. Windows Server 2019/2022), stammt die Liste aus der Registry – dann ohne Update-Prüfung.

| Status | Bedeutung |
|---|---|
| Update verfügbar | Neuere Version in der Quelle (Tooltip: alt → neu) |
| Aktuell | Keine neuere Version |
| Nicht über winget | Kein Paket in einer winget-Quelle – Aktualisierung über den Hersteller |
| Läuft … / Aktualisiert / Fehler | Während bzw. nach einer Aktualisierung; Fehlerursache und Code im Tooltip |

- **Ausgewählte aktualisieren**: alle angehakten Pakete (auch Store-Apps oder Pakete mit unbekannter Version).
- **Alle Updates installieren**: nur Pakete der Quelle `winget` mit bekannter Version.
- Aktualisiert wird still (`winget upgrade --id … --exact --silent`), im Hintergrund Paket für Paket, mit Fortschrittsbalken (gesamt und aktuelles Paket); **Abbrechen** stoppt nach dem aktuellen Paket. Danach wird die Liste neu geprüft.
- Nur mit Adminrechten. Auf einem RDS-Host vorher Benutzer abmelden bzw. Anmeldungen sperren (`change logon /drain`), weil laufende Programme beendet werden können.

### Windows Update

Oben zeigen Karten: **Betriebssystem** (Version, Build, Produktname bei Microsoft), **Update-Quelle** (Windows Update, Microsoft Update oder WSUS – nur Anzeige, wird nicht umgestellt), **Dienst** (Starttyp von `wuauserv`), **letzte Installation**, **Neustart** (ausstehend?) und **Sicherheit** (nach der CVE-Prüfung). Hinweisleisten erscheinen bei ausstehendem Neustart (mit „Jetzt neu starten …“), deaktiviertem Dienst und nicht mehr unterstützter Windows-Version (bzw. Windows 10 nur noch mit ESU).

| Reiter | Inhalt |
|---|---|
| Verfügbar | Ergebnis der Suche bei der eingestellten Update-Quelle (läuft im Hintergrund, oft 20 s bis einige Minuten): Kategorie (Kumulativ, Sicherheit, Definitionen, Treiber, Feature …), Schweregrad, maximale Downloadgröße, Status. **Ausgewählte installieren** bzw. **Wichtige installieren** (alles außer Treibern und optionalen Updates) – nur mit Adminrechten, Update für Update im Hintergrund mit Fortschritt; **Abbrechen** stoppt nach dem aktuellen Update. Danach wird neu gesucht; ist ein Neustart nötig, fragt das Tool nach (Neustart nach 60 s, abbrechen mit `shutdown /a`). |
| Installiert | Update-Verlauf von Windows Update (ohne Store-Apps) plus Hotfixes, die dort fehlen. Filter: Updates (ohne Defender-Definitionen), Alle, Fehlgeschlagen – Fehler mit Erklärung im Tooltip. |
| Sicherheitslücken | Nur auf Knopfdruck **„Sicherheitslücken prüfen (online)“**: fragt `api.msrc.microsoft.com` (Microsoft Security Update Guide) nach dem eigenen Produkt ab (z. B. „Windows 11 Version 24H2 for x64-based Systems“, „Windows Server 2022 (Server Core installation)“; übertragen werden nur Produktname und Zeitraum). Offen ist eine CVE, wenn ihr Korrektur-Build über dem installierten Build liegt. Angezeigt: CVE, Titel, Schweregrad, CVSS, Auswirkung, **ausgenutzt**, behebende KB mit Build und ob das Update in „Verfügbar“ angeboten wird. Darüber eine Zusammenfassung je KB. „CVE-Details“ (oder Doppelklick) und „KB im Katalog“ öffnen die Microsoft-Seiten. |

- Liegen nach dem letzten Microsoft-Eintrag für das Produkt zwei oder mehr Patchdays, warnt das Tool: Diese Version erhält keine Sicherheitsupdates mehr.
- Geprüft werden die letzten 13 Monate; bei länger nicht aktualisierten Systemen weist die Zusammenfassung darauf hin.
- Ohne Internet, hinter einer blockierenden Firewall oder bei Insider-Builds (Produkt unbekannt) erscheint ein Hinweis statt der Liste.

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
