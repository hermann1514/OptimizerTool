# Entscheidungen

## 2026-11-23 – BIS-F-Abgleich: Versiegeln und Startaufgabe ergänzt, mit Abweichungen
**Kontext:** Abgleich mit dem BIS-F-Quellcode (develop, 00/01/02/90/97). Dazu das Nutzerproblem, dass neue PVS-VMs mit wiederverwendetem Namen einen alten DNS-A-Eintrag behalten.
**Entscheidung:**
- Kein Versiegeln auf nicht-persistentem Image (PVS-Standard-Modus, MCS Shared), wie BIS-F; Abbruch vor jeder Änderung.
- DHCP-Reste: nur die Lease-Werte (`Dhcp*`) werden gelöscht. Statische `NameServer`/`Domain` bleiben, anders als bei BIS-F, das sie auf allen Adaptern leert (würde feste DNS-Einstellungen zerstören).
- MSMQ-QMId wird beim Versiegeln zurückgesetzt statt bei jedem Start (BIS-F Pers 02). Nicht-persistente Klone starten immer aus dem versiegelten Stand, die Wirkung ist gleich; kein Dienstneustart beim Start.
- DNS: Ein A-Eintrag, der einem früheren Computerkonto gehört, kann der Klon bei sicheren Updates nicht ändern. Die Startaufgabe erkennt und meldet es (Protokoll, Ereignis 1001) und registriert einmal neu; die Behebung gehört auf den DNS-/DHCP-Server (Hinweis `hint.dnsstale`).
- Buchstabenkorrektur nur bei genau einer Datenpartition auf weiteren Platten; CD-Laufwerke werden nur vom Cache-Buchstaben weg verschoben. Schleifenschutz über eine Merkdatei auf der Cache-Platte (C: ist im Standard-Modus nicht persistent).
- Citrix-Cache auf der Cache-Disk nicht übernommen: BIS-F setzt `CacheLocation` nur bei XenApp 6.5 und legt den Ordner nur ohne VDA an.
**Folgen:** Vorhandene Startaufgaben gelten wegen des neuen Skriptinhalts als „Offen“ und werden beim nächsten Versiegeln erneuert.

## 2026-11-20 – PVS: TCP Task Offload bleibt aktiv
**Kontext:** `DisableTaskOffload = 1` stammt aus einer alten Citrix-Empfehlung (XenServer-Retries, CTX117491). Aktuelle PVS-Dokumentation nennt sie nicht mehr; CTX692826 führt SOAP-Fehler auf den Wert zurück und rät, nur nach Tests vom Standard abzuweichen.
**Entscheidung:** Standard ist der Windows-Standard (Wert fehlt). Der Punkt `sys.taskoffload` entfernt einen gesetzten Wert; neue Id, weil die alte Sicherung `reg.taskoffload` vom Typ Registry ist.
**Folgen:** Eine alte Sicherung unter `reg.taskoffload` bleibt ungenutzt in `rdsopt_original.json`.

## 2026-11-08 – Windows Update: WUA-COM in Worker-Prozessen, CVE-Abgleich über den Security Update Guide
**Kontext:** Neue Seite für installierte/verfügbare Updates, Installation und betroffene CVEs des laufenden Systems; Nutzervorgaben: CVE-Abfrage nur auf Knopfdruck, Treiber einzeln wählbar (nicht in „Wichtige“), Update-Quelle wie konfiguriert.
**Entscheidung:**
- Windows Update Agent (COM) statt `UsoClient`/PSWindowsUpdate (keine Abhängigkeit, dokumentiert). Suche/Installation dauern Minuten, deshalb eigene PowerShell-Prozesse mit JSON-Ergebnis und Fortschrittsdatei; Worker-Skript als Temp-Datei, bewusst nicht `-EncodedCommand` (wird von EDR-Produkten als verdächtig gemeldet).
- Keine Umstellung der Quelle: WSUS wird nicht umgangen, Microsoft Update nicht registriert – nur angezeigt.
- CVEs über die SUG-API (`api.msrc.microsoft.com/sug/v2.0`, öffentlich, ohne Schlüssel, vom Microsoft-Portal genutzt) statt CVRF: CVRF-Monatsdokumente sind mehrere MB groß und nicht nach Produkt filterbar. Abgleich über `fixedBuildNumber` (kumulative Updates), deutsche Texte über `de-DE`. Risiko: API nicht formal dokumentiert, einige Abfrageformen (`$select`, `startswith`) blockiert die Firewall – nur getestete Muster, Fehler werden als Hinweis angezeigt.
- Unterstützungsende datengetrieben (Patchdays seit dem letzten Microsoft-Eintrag für das Produkt) statt fester Lebenszyklustabelle; nur Windows 10 22H2 (ESU) als fester Hinweis.
**Folgen:** CVE-Prüfung braucht Internetzugang zu `api.msrc.microsoft.com` (Systemproxy wird genutzt). Insider-Builds sind dort nicht verzeichnet.

## 2026-11-08 – Windows-Tweaks: Gerüst und Ablage der RDS-Optimierung, Standardprofil, einmalige Aktionen
**Kontext:** Neue Seite mit allgemeinen Tweaks für das laufende Windows; Nutzervorgaben: einzeln auswählbar mit Erklärung, Benutzer-Tweaks wahlweise für aktuellen Benutzer / zusätzlich Standardprofil / nur rechnerweit, nicht umkehrbare Aktionen als eigener Bereich, Wiederherstellungspunkt auf Clients.
**Entscheidung:**
- Gleicher Katalog-/Status-/Undo-Mechanismus und **gemeinsame Ablage** `rdsopt_original.json` (Dateiname bleibt aus Kompatibilität). Punkte, die es schon in der RDS-Optimierung gibt, werden per Id übernommen statt doppelt definiert – so gibt es je Einstellung nur einen Originalzustand.
- Standardprofil: `NTUSER.DAT` des Default-Profils wird nur für Status/Anwenden/Rückgängig geladen (`HKU\WinOptDefault`) und sofort wieder entladen. `Software\Classes` wird dort nicht geschrieben (liegt beim Benutzer in UsrClass.dat).
- Einmalige Aktionen sind die zweite Ausnahme vom Undo-Prinzip (neben „Versiegeln“): getrennt aufgelistet, nie vorausgewählt, Warnung in der Rückfrage, nur Zeitpunkt `last:<Id>` gespeichert.
- Wiederherstellungspunkt per `Checkpoint-Computer`, die 24-Stunden-Sperre von Windows wird nicht umgangen; Computerschutz wird nicht automatisch eingeschaltet.
- Werte aus WinUtil (MIT) und Microsoft-Dokumentation übernommen, eigener Code. Weggelassen: umstrittene/wirkungslose Tweaks (Auslagerungsdatei, Registry-Cleaner, LargeSystemCache, IPv6 aus, Indexdienst aus, BitLocker aus).
**Folgen:** Anwenden auf einer Seite markiert die andere zum Neu-Prüfen. Reine HKCU-Tweaks sind ohne Adminrechte änderbar; läuft das Tool als anderer Administrator, treffen sie dessen Profil.

## 2026-11-06 – Vorauswahl von Diensten nur bei sicherer Nicht-Nutzung
**Kontext:** Alle als „Deaktivierbar“ eingestuften Dienste waren auf der Seite „RDS-Optimierung“ vorausgewählt; Nutzervorgabe: nur, wenn sie auf dem RDS-Host zu 100 % ungenutzt sind.
**Entscheidung:** Positivliste `$script:RdsSafeServices` (fehlende VM-Hardware, Consumer-/Spiele-/Mixed-Reality-Funktionen, reine Diagnose-Telemetrie ohne Abhängigkeiten). Alles andere wird „Prüfen“ mit Grund aus `$script:RdsServiceCaution`; neue Regeln ohne Eintrag in der Positivliste sind automatisch „Prüfen“. Die Einstufung auf der Seite „Dienste“ bleibt „Deaktivierbar“.

## 2026-11-06 – Software-Updates über winget-CLI im Hintergrundprozess
**Kontext:** Installierte Software soll auf Updates geprüft und aktualisiert werden, ohne neue Abhängigkeiten.
**Entscheidung:** winget-Kommandozeile statt PowerShell-Modul `Microsoft.WinGet.Client` (müsste nachinstalliert werden). Ausgabe von `winget list` wird anhand der Spaltenpositionen der Kopfzeile zerlegt (funktioniert mit lokalisierten Überschriften; umgeleitete Ausgabe ist ungekürzt). winget läuft als eigener Prozess mit Ausgabedatei, ein DispatcherTimer prüft das Ende – die Oberfläche bleibt bedienbar. „Alle Updates“ nur für Quelle `winget` mit bekannter Version; Store-Apps/unbekannte Versionen nur gezielt. Keine eigene Ausschlussliste (winget-Pins nutzen).
**Folgen:** Abhängig vom Tabellenformat der winget-CLI; ohne winget nur Registry-Liste.

## 2026-11-06 – Startmenü: Ausblenden per Ablage, Einschränken per NTFS-Rechte
**Kontext:** Auf RDS-Hosts sollen Einträge des gemeinsamen Startmenüs für alle oder nur für bestimmte Gruppen sichtbar sein.
**Entscheidung:** „Ausblenden“ verschiebt die Verknüpfung nach `C:\ProgramData\WindowsOptimizer\StartMenuHidden\<relativer Pfad>` – bewusst außerhalb von „Start Menu“, weil das Startmenü alles darunter anzeigt. „Nur für Gruppen“ setzt geschützte Rechte (SYSTEM + Administratoren Vollzugriff, gewählte Gruppen sowie „Alle Anwendungspakete“ Lesen); Benutzer ohne Leserecht sehen den Eintrag nicht. Ursprüngliche DACL je Datei (SDDL) wird beim ersten Einschränken in `backups\startmenu_original.json` gespeichert und bei „Für alle sichtbar“ zurückgeschrieben. Rechte werden mit `[IO.File]::SetAccessControl` geschrieben (nur DACL; `Set-Acl` würde auch den Besitzer setzen wollen).
**Folgen:** Wirksam ab der nächsten Anmeldung; Administratoren sehen alles; Software-Updates können Verknüpfungen neu anlegen (dann wieder für alle sichtbar). Store-Apps nur Anzeige.

## 2026-11-06 – BIS-F als Quelle: nur Fakten übernehmen, keinen Code
**Kontext:** BIS-F (Base Image Script Framework) enthält viele bewährte Image-Optimierungen, steht aber unter GPL-3.0.
**Entscheidung:** Übernommen werden nur Einstellungen, Registry-Werte, Erkennungsmerkmale und Befehle; die Umsetzung ist eigener Code im Katalog-Stil des Projekts. Nicht übernommen: DEP aus (Sicherheit), DHCP-Werte leeren (veralteter Workaround), ngen (blockiert die Oberfläche), Drittanbieter-Tools.
**Folgen:** Projektlizenz bleibt unabhängig von BIS-F.
**Ergänzung 06.11.2026:** „RDS-Kulanzfrist zurücksetzen“ wurde zunächst ausgelassen, auf Nutzerentscheidung aber als Versiegeln-Schritt aufgenommen (mit dem Hersteller abgestimmter Image-Workaround). Abweichend von BIS-F werden Besitzer und Rechte des GracePeriod-Schlüssels danach wiederhergestellt; Hinweis im Tool: ersetzt keine RDS-CALs.

## 2026-11-06 – „Versiegeln“ als bewusste Ausnahme vom Undo-Prinzip
**Kontext:** Aufräumschritte vor dem Verteilen eines Images (Kennungen, Caches, Ereignisprotokolle) lassen sich naturgemäß nicht umkehren.
**Entscheidung:** Nicht als einzelne Punkte in der Optimierungsliste, sondern gesammelt über den Button „Versiegeln und herunterfahren“ (`Get-SealSteps`, `Invoke-SealAndShutdown`), weil sie bei jeder Image-Aktualisierung immer vollständig nötig sind. Vorher Liste der auszuführenden und übersprungenen Schritte mit Rückfrage, automatische Sicherung; nur Zeitpunkt des letzten Laufs gespeichert (`seal:last` in `rdsopt_original.json`). Bei Fehlern zweite Rückfrage vor dem Herunterfahren.
**Ergänzung 18.11.2026:** Wie BIS-F setzt das Versiegeln fehlende Umleitungen auf das Cache-Laufwerk (Ereignisprotokolle, Auslagerungsdatei usw.) und fährt danach direkt herunter (kein Zwischen-Neustart, auf Nutzerentscheidung). Diese Umleitungen bleiben normale Katalogpunkte mit gesichertem Ursprung und sind damit, anders als die übrigen Schritte, rückgängig machbar.

## 2026-11-18 – Startaufgabe formatiert eine neue Cache-Platte nur im eindeutigen Fall
**Kontext:** Nach Austausch der persistenten Platte ist die neue RAW (ohne Dateisystem und Buchstaben); alle Umleitungen zeigen ins Leere.
**Entscheidung:** Die Startaufgabe richtet die Platte nach 3 min Wartezeit selbst ein (GPT, NTFS, Cache-Buchstabe) und startet einmal neu – aber nur bei genau einer leeren RAW-Platte ohne Partitionen, freiem Buchstaben und nicht bei MCS (MCSIO verwaltet die Platte selbst; nicht-persistente Cache-Platte würde eine Neustart-Schleife auslösen). Kein Neustart, wenn im Lauf Fehler auftraten.
**Folgen:** Formatieren ist nicht umkehrbar, daher keine Heuristik für mehrdeutige Fälle (CD auf dem Buchstaben, mehrere leere Platten) – dort nur Protokolleintrag.

## 2026-11-06 – RDS-Optimierung: Undo je Punkt über eigene Ablage
**Kontext:** Optimierungen (Registry, Aufgaben, Dienste, powercfg) sollen einzeln rückgängig machbar sein, auch nach Neustart des Tools.
**Entscheidung:** Beim ersten Anwenden eines Punkts wird dessen Ausgangszustand in `backups\rdsopt_original.json` geschrieben (Registry: Wert, Typ oder „fehlte“; Aufgabe an/aus; Starttyp; powercfg-Wert). Erneutes Anwenden überschreibt ihn nicht; „Rückgängig“ stellt ihn her und entfernt den Eintrag. Zusätzlich `.reg`-Export der betroffenen Schlüssel und die normale Sitzungssicherung.
**Folgen:** Nicht umkehrbare Maßnahmen (z. B. Apps entfernen) bleiben außen vor. Nicht in der JSON-Sicherung/Wiederherstellung der Seite „Sicherung“ enthalten (außer Dienst-Starttypen).

## 2026-11-06 – Autostart deaktivieren durch Verschieben statt StartupApproved
**Kontext:** Bis 1.1.0 wurde wie im Task-Manager nur `…\Explorer\StartupApproved` auf „aus“ gesetzt. In der Praxis starteten so gesperrte Programme beim Nutzer trotzdem (Sperre wird nicht von allen Programmen/Startwegen beachtet bzw. von Programmen zurückgesetzt).
**Entscheidung:** Deaktivieren verschiebt den Eintrag in eine Ablage, die Windows nicht auswertet (Prinzip Sysinternals Autoruns):
- Registry: `<Run>\WindowsOptimizerDisabled` (Unterschlüssel)
- Autostart-Ordner: `<Startup>\WindowsOptimizerDisabled` (Unterordner)
Aktivieren schreibt Name, Typ und Rohtext unverändert zurück und hebt eine evtl. StartupApproved-Sperre auf. Nichts wird endgültig gelöscht; Reihenfolge immer „erst schreiben, dann löschen“.
**Folgen:**
- Ausgeschaltete Einträge erscheinen nicht mehr im Task-Manager.
- Alte StartupApproved-Sperren werden erkannt („nur Task-Manager-Sperre“) und per Button in die Ablage überführt.
- Programme, die sich selbst neu in Run eintragen, erscheinen wieder als aktiv; der aktive Eintrag gewinnt, die Ablagekopie wird beim Einschalten verworfen.
- Sicherungen bleiben kompatibel (Id `SourceId|ValueName` unverändert).

## 2026-11-18 – Terminalserver: ohne wirksame Shared Computer Activation kein Versiegeln
**Kontext:** Microsoft 365 Apps auf RD-Sitzungshosts sind nur mit SCA zulässig; eine Richtlinie `SharedComputerLicensing = 0` hat Vorrang vor der Click-to-Run-Konfiguration.
**Entscheidung:** Beim Versiegeln eines RD-Sitzungshosts wird fehlende SCA ohne Rückfrage gesetzt (Punkt `reg.officesca`, rückgängig machbar) und erneut geprüft; ist sie dann nicht wirksam, bricht das Versiegeln ab. Bereinigt wird nur das Office-Profil des versiegelnden Admins; Benutzerprofile (FSLogix) bleiben unberührt, damit bereits aktivierte Benutzer weiterarbeiten. Ob das Token im Profil erhalten bleibt, wird nur geprüft und gewarnt, nicht geändert.

## 2026-11-19 – SentinelOne-Passphrase wird nicht gespeichert
**Kontext:** `SentinelCtl agent_id -r -b` braucht die Passphrase des Agents. Erwogen wurde, sie verschlüsselt abzulegen.
**Entscheidung:** Sie wird bei jedem Versiegeln verdeckt abgefragt, nur für den Aufruf im Speicher gehalten und in Protokoll und Fehlermeldungen maskiert. Ablehnen überspringt den Schritt, das Versiegeln läuft weiter.
**Gründe:** Die Passphrase gehört zur Agent-UUID. Nach `-r -b` bzw. im VDI-Modus bekommt der Master eine neue UUID, eine gespeicherte Passphrase wäre beim nächsten Versiegeln also veraltet. Außerdem läge sie im Master-Image und damit auf jedem Klon (DPAPI mit LocalMachine-Schutz kann dort jeder lokale Admin entschlüsseln).
**Folgen:** Die Passphrase steht beim Aufruf kurz in der Befehlszeile von SentinelCtl, das ist bei diesem Werkzeug nicht vermeidbar.

## 2026-11-18 – BIS-F-Deinstallation: vollständig entfernen, Windows-Einstellungen behalten
**Kontext:** Das Tool löst BIS-F auf bestehenden Images ab. BIS-F speichert die Originalwerte der von ihm geänderten Windows-Einstellungen nicht.
**Entscheidung:** Eigene Seite, nur sichtbar bei Fund. Entfernt werden alle BIS-F-Bestandteile (Aufgaben zuerst, dann MSI, dann Reste, Richtlinien lokal); Suche dynamisch, gelöscht wird nur, was angezeigt wurde. Ereignisprotokoll-, Spooler-, Auslagerungs- und WEM-Einstellungen bleiben und werden von den Cache-Laufwerk-Punkten des Tools übernommen. Nicht umkehrbar (wie Versiegeln); Sicherung der Schlüssel und Aufgaben nur zur Nachverfolgung.
