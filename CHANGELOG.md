# Changelog

## 1.17.2 – 2026-11-25
- **Fehler behoben: Die Anmeldeanalyse rechnete die Abmeldung der vorherigen Sitzung mit.** Meldet sich derselbe Benutzer kurz nach einer Abmeldung wieder an, lagen deren Winlogon-Ereignisse in der 30-s-Kette. Am Target begann die Anmeldung dadurch 29 s zu früh. Statt der Anmeldung zählte das Abhängen des FSLogix-Containers (`frxsvc`, 5 s).
  - Die Startkette folgt nur noch den Benachrichtigungen 0 (Sitzung anlegen) und 2 (Logon).
  - Abmelde-Benachrichtigungen (3 Logoff, 13 EndShell) fallen aus der Abonnentenliste.
- **Text von `sys.runlock.teams` korrigiert:** Nach der Sperre startet Teams gar nicht mehr automatisch (am Target bestätigt), nicht nur einmal. Benutzer können „Teams automatisch starten“ in Teams wieder einschalten.

## 1.17.1 – 2026-11-24
- **PVS-Vorladen: Platzhalter `*`/`?` in Pfaden.**
  - Aufgelöst wird beim Start, die neuesten Treffer zuerst, jeder Treffer einzeln im Protokoll (`Resolve-PreloadPath`).
  - Beispiel: `C:\Program Files\WindowsApps\MSTeams_*`. Der Ordner trägt die Version im Namen.
- **Vorschlag gezielter**, in dieser Reihenfolge (Vorrang an der Grenze): Teams (Store-App), WebView2, Edge, `Microsoft Office\root\Office16` statt ganz `root` (ohne vfs/DataModel), Chrome.
- **Neuer Knopf „Vorschlag einsetzen“**, weil gespeicherte Einstellungen die alte Liste behalten.
- **„In den Schreibcache“:** Dateien unter WindowsApps und im Windows-Ordner werden nur gelesen, nie zurückgeschrieben.

## 1.17.0 – 2026-11-24
- **Fehler behoben: PVS-Vorladen lief auf Targets nie.**
  - Das Startskript hielt jede `.avhdx` für eine Wartungsversion. Bei Versionierung ist aber jede Version eine `.avhdx`, auch die Produktionsversion.
  - Übersprungen wird jetzt nur noch bei WriteCacheType 0/10 (Schreibzugriff). Die Version steht im Protokoll.
- **Die Erkennungskarte** zeigt „Version n“ statt fälschlich „Wartungsversion“.
- **Vorladen „in den Schreibcache“** auch mit Cache-Typ 12 (RAM mit Überlauf, asynchron). Bisher wurde dabei auf Lesen zurückgefallen.
- **Neue Gruppe „Anmeldung“:** Autostarts im Benutzerprofil per Active Setup sperren, gesetzt wird `StartupApproved\Run = 03` einmal je Benutzer vor den Autostarts. Stufe „Prüfen“, rückgängig machbar, erscheint nur bei Fund:
  - `sys.runlock.teams`: Run-Eintrag „Teams“ (doppelter Start neben der Startaufgabe des Pakets)
  - `sys.runlock.adobe`: „Adobe Acrobat Synchronizer“ (AdobeCollabSync)

## 1.16.1 – 2026-11-24
Anmeldeanalyse geschärft (nach der ersten Messung auf dem PVS-Target):
- Zeiten zählen jetzt ab Beginn der Winlogon-Anmeldung, also ab dem frühesten Winlogon-Abonnenten vor dem Profildienst (Lücke ≤ 30 s). Bisher galt der Eingang beim Profildienst. Die Zeit der FSLogix-Abonnenten `frxsvc`/`frxmid`, die vorher laufen, fehlte dadurch.
- Neue Meilensteine: „FSLogix fertig“, „Autostart beginnt“ und „Autostart fertig“. Bei „Profil geladen“ steht zusätzlich die Dauer des Profildienstes. Die Winlogon-Abonnenten zeigen ihren Startzeitpunkt, FSLogix ist beschriftet.
- Neu aus dem Application-Log: Abstürze (1000, mit Modul und Code) und Hänger (1002) von Suche, Startmenü und Explorer.
- Neue Hinweise:
  - FSLogix über 5 s
  - Lücke über 15 s zwischen „Desktop bereit“ und erstem Autostart (Tweak „Autostart-Verzögerung aus“)
  - abstürzendes Modul der Suche
  - Absturzeinträge fehlen trotz WSearch-Abstürzen (Fehlerberichterstattung)
  - Hänger von Startmenü/Explorer

## 1.16.0 – 2026-11-24
- RDS-Seite: neuer einklappbarer Bereich „Anmeldeanalyse“. Er liest die Ereignisse einer gewählten Anmeldung der letzten 7 Tage aus den Protokollen User Profile Service, Winlogon, Shell-Core, AppReadiness und System. Er zeigt:
  - Meilensteine: Profil geladen, Desktop bereit, Startmenü-Host gestartet, App-Vorbereitung fertig
  - Winlogon-Abonnenten (z. B. Gruppenrichtlinien)
  - Shell-Anmeldeaufgaben (Active Setup, RunOnce, AppReadiness …)
  - Autostart-Befehle
  - registrierte AppX-Pakete
  - Abstürze der Windows-Suche
  - Hinweise nach Regeln
- Die Analyse ist nur lesend und lässt sich als Text kopieren. Ohne Administratorrechte sind nur die eigenen Anmeldungen lesbar.

## 1.15.0 – 2026-11-24
Aus der Ereignisprotokoll-Analyse eines PVS-Targets (docs/rds-eventlog-analyse.md):
- Update-Aktivität auf PVS/MCS: neue Punkte `reg.wuauto` (`NoAutoUpdate = 1`), `reg.storeauto` (`AutoDownload = 2`), `reg.officeupdate` (Office C2R: `enableautomaticupdates = 0`, `hideenabledisableupdates = 1`, Applies `OfficeC2RImage`), `sys.browserupd` (Dienste/Aufgaben von Edge- und Google-Updater per Platzhalter aus, `AutoUpdateCheckPeriodMinutes = 0`; nur wenn vorhanden)
- Dienst-Abhängigkeiten (Ereignis 7001): Punkt `sys.svcdeps` setzt deaktivierte Abhängigkeiten von Autostart-Diensten auf „Manuell“ (z. B. CDPSvc → NcbService), rückgängig machbar; deaktivierbare Dienste mit abhängigen Diensten sind nicht mehr vorausgewählt (Grund im Tooltip)
- Versiegeln: neuer Schritt „Windows-Suchindex zurücksetzen“ (PVS/MCS, nur mit aktiver Windows-Suche) vor „DHCP-Reste entfernen“
- Neuer Punkt `sys.tlsclient` (Prüfen): entfernt `Enabled = 0`/`DisabledByDefault = 1` unter SCHANNEL TLS 1.2/1.3 Client (gegen Schannel 36871/10013); zeigt TLS-1.0/1.1-Sperren, Cipher-Suite-Richtlinie und FIPS-Modus als Information

## 1.14.0 – 2026-11-24
- Neuer PVS-Punkt „Dateien beim Start vorladen“ (`sys.pvspreload`, Citrix CTX477629): eigene Startaufgabe „PVS-Dateien vorladen“ (SYSTEM, Priorität 7) mit `%ProgramData%\WindowsOptimizer\Preload-PvsFiles.ps1` und `PvsPreload.json`, rückgängig machbar
- Zwei Methoden: „nur lesen“ wie BIS-F (`10_PersBISF_HydratePVS.ps1`, jedoch in 1-MB-Blöcken statt `ReadAllBytes`, mit Grenze) oder „in den Schreibcache“ (gleicher Inhalt blockweise zurückgeschrieben, Rechte/Zeitstempel bleiben; gesperrte Dateien werden nur gelesen; nur bei Cache-Typ 3/4/9, sonst Rückfall auf Lesen)
- Aufgabe tut im Privat-Modus und in Wartungsversionen nichts; Verknüpfungspunkte werden übersprungen; Protokoll `<Cache-Laufwerk>\WindowsOptimizer\Preload.log` bzw. `%ProgramData%\WindowsOptimizer\Preload.log`
- RDS-Seite: einklappbarer Bereich „PVS: Dateien beim Start vorladen“ (nur bei PVS) mit Pfaden, Endungen, Methode, Grenze, „Größe ermitteln“ und „Speichern“; Vorschlag Edge, Chrome, Office (nur vorhandene Ordner)
- `Initialize-TaskScriptFolder`: Ordner-Rechte der Startskripte aus `Install-CacheBootTask` herausgelöst (unverändert)

## 1.13.1 – 2026-11-23
- Fehler behoben: Versiegeln-Schritt „DHCP-Reste entfernen“ schlug fehl, weil der abhängige Dienst `WinHttpAutoProxySvc` sich ab Windows 10/Server 2019 nicht beenden lässt (Versiegeln dadurch mit Fehler, Herunterfahren abgelehnt). Jetzt: DHCP-Client wird nur gestoppt, wenn alle laufenden Abhängigen beendbar sind; sonst Warnung im Protokoll, Lease-Angaben werden bei laufendem Dienst entfernt
- `Stop-SealService`: bricht vor dem Stoppen ab, wenn ein laufender abhängiger Dienst nicht beendbar ist (kein unnötiges Stoppen von WlanSvc, Wcmsvc, iphlpsvc …); bei Teilerfolg werden bereits gestoppte Dienste gemerkt

## 1.13.0 – 2026-11-23
- Versiegeln gesperrt auf nicht-persistentem Image (PVS-Standard-Modus, MCS Shared) wie bei BIS-F: Abbruch vor jeder Änderung mit Erklärung, Button gesperrt mit Tooltip
- Versiegeln: neuer letzter Schritt „DHCP-Reste entfernen“ (PVS): DHCP-Client stoppen, je Adapter `DhcpIPAddress`, `DhcpSubnetMask`, `DhcpServer`, `DhcpNameServer`, `DhcpDefaultGateway` löschen; statische DNS-Server/-Suffixe bleiben (nur protokolliert)
- Versiegeln: neuer Schritt „MSMQ: neue Kennung für Klone“ (PVS/MCS, nur mit MSMQ): `QMId` löschen, `SysPrep = 1`, `LogDataCreated = 0`
- Neuer Punkt „ARP-Erreichbarkeit 600 s je Netzwerkadapter“ (PVS, CTX127549, `basereachable=600000`), rückgängig machbar; Katalogpunkte mit `Seal = $true` setzt das Versiegeln automatisch, falls offen
- Neuer Punkt „Ereignisprotokolle begrenzen“ (Gruppe Cache-Laufwerk, auch beim Versiegeln): aktive Protokolle höchstens 64 MB (Security 256 MB), „Archivieren, wenn voll“ → „Überschreiben“; GPO-Vorgaben bleiben, rückgängig machbar
- Startaufgabe: CD/DVD auf dem Cache-Buchstaben wird verschoben (Buchstabe des Masters bzw. höchster freier); vorhandene Cache-Platte mit falschem/fehlendem Buchstaben (genau eine Datenpartition) erhält den Cache-Buchstaben, danach ein Neustart (Schleifenschutz 30 min, Merkdatei `LetterFix.txt`)
- Startaufgabe: Zeitabgleich mit der Domäne (`w32tm /config /update`, `/resync /nowait`), Prüfung des eigenen DNS-A-Eintrags (bis 3 min warten, sonst `Register-DnsClient`; bleibt der alte Wert: Warnung mit DNS-Client-Ereignissen 8015–8020 und Ereignis 1001, Quelle `WindowsOptimizer`, im Anwendungsprotokoll); Größe der Ereignisprotokolle und `Archive-*.evtx` auf dem Cache-Laufwerk; Laufzeitgrenze 15 min
- Hinweis „Alter DNS-Eintrag bei wiederverwendeten Rechnernamen“ (PVS) mit Abhilfe auf dem DNS-/DHCP-Server
- Text bei „ohne Herunterfahren“: nennt die gestoppten Dienste (WEM-Agent, DHCP-Client, MSMQ)

## 1.12.0 – 2026-11-20
- Versiegeln: Häkchen „Danach herunterfahren“ (Standard an, Knopftext passt sich an). Aus: Sitzung bleibt zur Kontrolle offen, Zusammenfassung mit Angebot, das Protokoll zu öffnen; gestoppte Dienste (WEM-Agent) bleiben gestoppt
- Versiegeln: eigenes Protokoll je Lauf `logs\versiegeln_<Datum>_<Uhrzeit>.log` (Version, Rechner, Benutzer, Erkennung, Office/SCA, übersprungene Schritte mit Grund, jeder Schritt mit OK/FEHLER, Dauer und Meldungen aus dem Schritt, Zusammenfassung, Herunterfahren ja/nein); Verweis im Tagesprotokoll
- Fehler behoben (seit 1.9.0): Die festen Versiegeln-Schritte (WSUS-Kennung, Caches, Ereignisprotokolle …) schlugen alle mit „Der Schlüssel darf nicht NULL sein“ fehl, weil `$s.Item` bei Hashtabellen ohne Schlüssel `Item` die eingebaute Item-Eigenschaft liefert. Nur die Umleitungsschritte liefen

## 1.11.1 – 2026-11-20
- PVS: „TCP Task Offload aus“ (`reg.taskoffload`, `DisableTaskOffload = 1`) ersetzt durch „TCP Task Offload aktiv (Windows-Standard)“ (`sys.taskoffload`): entfernt den Wert, umgesetzt wenn er fehlt oder 0 ist; Ursprungswert gesichert, rückgängig machbar

## 1.11.0 – 2026-11-19
- SentinelOne-Agent wird erkannt (Dienst `SentinelAgent`, `SentinelCtl.exe`, Version), angezeigt in der Plattform-Karte und in der Kurzfassung
- Versiegeln: neuer Schritt „SentinelOne: neue Agent-Kennung für Klone“ (nur PVS/MCS). Er fragt die Passphrase verdeckt ab, führt `SentinelCtl agent_id -r -b -k` aus und prüft mit `agent_id -v`. Ohne Eingabe wird er übersprungen, das Versiegeln läuft weiter. Die Passphrase wird weder gespeichert noch protokolliert, auch nicht in Fehlermeldungen. Die Rückfrage zeigt den VDI-Status
- RDS-Optimierung: Hinweis „SentinelOne für Klone einrichten“ (Agent mit `VDI=true`, Konsole: eigene Gruppe, Auto-Decommission, „Scan New Agents“ aus)
- Eingabedialog unterstützt verdeckte Eingabe

## 1.10.3 – 2026-11-19
- Neuer Punkt „Speicherabbild nach <Cache-Laufwerk>“ (Gruppe Cache-Laufwerk, Empfohlen, auch beim Versiegeln): `DedicatedDumpFile` = `<LW>\DedicatedDump.sys` (2048 MB), `DumpFile` und `MinidumpDir` nach `<LW>\Dumps`. Ohne ihn entstand nach der Auslagerungsdatei-Umleitung kein Absturzabbild mehr (volmgr 49); Ursprung gesichert, rückgängig machbar
- Startaufgabe: legt die Abbild-Ordner auf neuen Cache-Platten an und warnt im Protokoll, wenn kein Abbild möglich ist (keine Auslagerungsdatei auf C: und kein `DedicatedDumpFile`) bzw. die Abbilddatei beim Start nicht angelegt wurde

## 1.10.2 – 2026-11-18
- RDS-Optimierung auf kleinen Bildschirmen/RDP: Die ganze Seite scrollt (ein Scrollbalken, pixelweise; Mausrad funktioniert auch über der Liste), die Liste zeigt alle Punkte statt nur des Restplatzes
- Erkennung einklappbar: Kopfzeile mit Kurzfassung (z. B. „Citrix VDA 7.41 · PVS (…) · WEM · Microsoft 365 (SCA aktiv)“); bei Arbeitsbereich unter 900 Pixel Höhe beim Start zugeklappt
- Zeilen „Cache-Laufwerk/Versiegeln“ und „Filter/Anwenden“ brechen bei wenig Breite um – „Anwenden“, „Rückgängig“ und „Zuletzt versiegelt“ werden nicht mehr abgeschnitten; Untertitel gekürzt

## 1.10.1 – 2026-11-18
- Fenster startet maximiert; die Größe für „Verkleinern“ (und das Mindestmaß) wird an den Arbeitsbereich angepasst – in kleinen RDP-Sitzungen ragt das Fenster nicht mehr über den Rand, die Titelleiste bleibt erreichbar und das Fenster verschiebbar
- MCS-Erkennung korrigiert: Machine Identity Service und MCSIO-Treiber installiert der VDA auf jedem System. MCS gilt jetzt nur bei MCS-Bereitstellung (Personality.ini ohne PVSAgent) oder bei MCS-Bestandteilen ohne PVS-Target-Software (MCS-Master). Auf PVS Target Devices: MCS und MCSIO nicht erkannt, MCS-Punkte „Nicht zutreffend“, MCS-Karte „nicht verwendet“ mit Hinweis

## 1.10.0 – 2026-11-18
- Neue Seite „BIS-F“ (Menüpunkt nur sichtbar, wenn BIS-F oder Reste gefunden werden): listet alle Bestandteile – Uninstall-Eintrag, geplante Aufgaben (Name, Pfad, Beschreibung oder Aktion mit BISF/BIS-F/Base Image Script), Registry- und Richtlinienschlüssel `…\BISF` (Login Consultants, EUCweb u. a.), Installations-, Startmenü- und Log-Ordner (auch aus Log-Pfaden im BISF-Schlüssel), ADMX/ADML; Startskripte der lokalen Gruppenrichtlinie nur als Hinweis
- „BIS-F deinstallieren …“: Aufgaben beenden und entfernen, `msiexec /x` (still, mit Protokoll; 0/3010/1605 = Erfolg), danach Ordner, Dateien, Registry und Richtlinien (leere Herstellerschlüssel mit); Sicherung der Schlüssel (.reg) und Aufgaben (.xml) vorab, Ergebnis je Bestandteil in der Liste, erneute Suche nach Resten
- Von BIS-F gesetzte Windows-Einstellungen bleiben; die Seite zeigt sie und warnt, wenn Umleitungen auf einem Cache-Laufwerk liegen, die Startaufgabe des Tools aber fehlt

## 1.9.0 – 2026-11-18
- Versiegeln wie BIS-F: Bei PVS/MCSIO mit gewähltem Cache-Laufwerk werden noch fehlende Umleitungen zuerst gesetzt (Ereignisprotokolle, Auslagerungsdatei, Spooler, WEM-Cache, NCPA-Protokolle, Startaufgabe), danach werden die Ereignisprotokolle geleert. Die Umleitungen sind normale Katalogpunkte mit gesichertem Ursprung, also über die Liste rückgängig machbar. Ohne gewähltes Cache-Laufwerk erscheinen sie als „übersprungen“; Hinweis, wenn die Auslagerungsdatei erst ab dem nächsten Start auf dem Cache-Laufwerk liegt
- Neuer Versiegeln-Schritt „WEM-Agent-Cache und -Protokolle entfernen“: stoppt den Agent, löscht LocalAgentCache/LocalAgentDatabase (Alternativort bzw. `Local Databases`) und `*.log` im Agent-Ordner; wird nicht heruntergefahren, startet das Tool die Dienste wieder
- NCPA (Nagios): Erkennung (Dienste `ncpa` bzw. `ncpalistener`/`ncpapassive`, `etc\ncpa.cfg`), neuer Punkt „NCPA-Protokolle nach <Cache>\NCPA“ (nur die `logfile`-Zeilen werden geändert, Kodierung bleibt erhalten, rückgängig machbar); die Startaufgabe legt den Ordner an und startet NCPA neu
- Die Startaufgabe gilt als „Offen“, wenn das installierte Skript nicht dem aktuellen Stand entspricht (z. B. 1.8.1 ohne NCPA-Abschnitt)
- Startaufgabe protokolliert ausführlich: Start (Rechner, Windows-Startzeit), Wartezeit und Angaben zum Cache-Laufwerk, je Bereich Pfad und Ergebnis (nicht auf dem Laufwerk / vorhanden / angelegt, Dienstneustart mit Status, Kontrolle der Systemprotokoll-Datei), konfigurierte und aktive Auslagerungsdatei (Warnung, wenn nicht auf dem Cache-Laufwerk aktiv), Ende mit Dauer, Warnungen, Fehlern und Rückgabewert. Protokoll jetzt auf dem Cache-Laufwerk unter `<Cache>\WindowsOptimizer\CacheDrive.log` (ab 1 MB als `.old` aufgehoben), ersatzweise unter `%ProgramData%\WindowsOptimizer`, wenn das Laufwerk fehlt. Rückgabewert 1 bei Fehlern
- Startaufgabe richtet eine neue, leere Cache-Platte ein (z. B. nach Austausch der persistenten Platte): Fehlt das Laufwerk nach 3 min und gibt es genau eine RAW-Platte ohne Partitionen (nicht System/Start, nicht USB/SD/VHD, ≥ 2 GB), wird sie initialisiert (GPT), mit NTFS „Cache“ und dem Cache-Buchstaben formatiert, mit `WindowsOptimizer\CacheDisk.txt` markiert und der Server einmal neu gestartet (nur ohne Fehler). Nichts wird formatiert bei mehreren leeren Platten, belegtem Buchstaben (z. B. CD-Laufwerk) oder MCS-Bereitstellung; alle Datenträger und der Grund stehen im Protokoll
- Shared Computer Activation: Erkennung korrigiert – wirksam ist die Richtlinie vor der Click-to-Run-Konfiguration (bisher galt SCA auch bei Richtlinie = 0 als aktiv). Office-Karte zeigt Quelle, Ort des Lizenz-Tokens (`SCLCacheOverride`/`-Directory`) und ob es im FSLogix-Profil erhalten bleibt (FSLogix installiert/aktiviert, Ausschluss in `redirections.xml`)
- Versiegeln auf Terminalservern: Fehlt SCA, wird sie ohne Rückfrage gesetzt und erneut geprüft; ist sie danach nicht wirksam (z. B. Domänen-GPO = 0), wird nicht versiegelt. Rückfrage zeigt SCA-Status, Erhalt der Benutzer-Aktivierung und noch laufende Office-Programme
- „Microsoft-365-Lizenzreste entfernen“ bereinigt im Profil des versiegelnden Admins zusätzlich `HKCU\…\Office\16.0\Common\Licensing` und die Office-Anmeldedaten in der Anmeldeinformationsverwaltung (`MicrosoftOffice1x_Data:*`); Benutzerprofile bleiben unberührt

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
