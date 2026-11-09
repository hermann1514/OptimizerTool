# Aktueller Stand

## Erledigt
- Erfassung Registry Run (HKCU, HKLM, HKLM 32-Bit) und Autostart-Ordner (Benutzer, alle)
- Systeminformationen (OS, Rechner, CPU, RAM, Grafik, Datenträger, Netzwerk), Kopieren als Text
- Sicherung (JSON + .reg), Wiederherstellung mit Vorschau, automatische Sicherungen
- Protokoll pro Tag, Anzeige im Tool
- 1.1.0: Seite „Dienste“ (Starttyp ändern, Citrix-RDS-Einstufung ~300 Regeln), Sicherung v2 mit Dienst-Starttypen
- 1.2.0: Umbenennung in Windows-Optimizer; Deaktivieren durch Verschieben in Ablage `WindowsOptimizerDisabled` (StartupApproved wirkte beim Nutzer nicht); Alt-Sperren markiert + „Endgültig deaktivieren“; eigenes App-Symbol + Taskleistengruppe
- Getestet 1.2.0 (Standardbenutzer, Testeinträge HKCU Run + Startordner-.lnk, danach entfernt): aus/an mit erhaltenem Werttyp, Alt-Sperre → Ablage, Konflikt (Programm trägt sich neu ein), Wiederherstellung Aktivieren/Neu anlegen, Rendering mit Symbol
- 1.3.0: Seite „RDS-Optimierung“ (Erkennung WEM/PVS/MCS, Katalog, einzeln anwenden/rückgängig)
- Getestet 1.3.0 (Standardbenutzer): Parser/BOM/XAML, Erkennung + Status aller 120 Punkte (~3 s), Undo-Roundtrip mit HKCU-Testschlüssel (fehlender Wert gelöscht, ExpandString erhalten, Ursprung nicht überschrieben), Rendering der Seite
- 1.4.0: BIS-F-Erkenntnisse (Erkennung PVS/MCS korrigiert, weitere Punkte, Cache-Laufwerk-Umleitung, Versiegeln)
- Getestet 1.4.0 (Standardbenutzer): Parser/BOM/XAML, Erkennung echt + simulierte MCS-Personality.ini, Katalog 141 Punkte mit simuliertem PVS/WEM/VMware und Cache-LW (~3,5 s), Undo Kind=Key (HKCU), Ereignisprotokoll-Pfade lesen + JSON-Roundtrip (1293 Protokolle), Rendering
- 1.5.0: Seite „Startmenü“ (für alle / ausblenden / nur Gruppen; Store-Apps nur Anzeige)
- Getestet 1.5.0 (Standardbenutzer): echtes Startmenü lesen (88 Verknüpfungen, 82 Store-Apps, ~2,7 s); Logik im TEMP-Ordner: ausblenden/einblenden, Gruppe „Remotedesktopbenutzer“ setzen → „Eingeschränkt“, zurück → SDDL identisch, unbekannte Gruppe abgelehnt; Rendering
- 1.6.0: Seite „Software“ (winget-Update-Prüfung, ausgewählte/alle aktualisieren im Hintergrund)
- Getestet 1.6.0 (Standardbenutzer): winget list über Ausgabedatei (197 Programme, 22 Updates, 21 für „Alle“, Umlaute korrekt, ~1,4 s), Registry-Ersatz (78), Fehlerweg mit nicht vorhandenem Paket (0x8A150014 „Paket nicht gefunden“), Rendering mit asynchronem Laden
- Nutzertest 1.6.0 (Admin): Bitwarden und Joplin einzeln erfolgreich aktualisiert; dabei gefunden und behoben: gesperrte winget-Ausgabedatei beim Neu-Prüfen, fehlende Anzahl bei einem Paket
- 1.6.1: „Deaktivierbar“-Dienste nur bei sicherer Nicht-Nutzung vorausgewählt (67 sicher, 35 „Prüfen“ mit Grund; auf dem Entwicklungsrechner 55 von 86 Dienst-Punkten vorausgewählt), Konsistenz geprüft (jede Regel genau einer Gruppe zugeordnet)
- Nutzertest 1.6.0 (Admin, 07.11.): Fehler „Datei wird von einem anderen Prozess verwendet“ kam von veralteter Desktop-Kopie (vor dem Fix); mit aktuellem Stand läuft es
- 1.6.2: Fortschrittsbalken bei Software-Updates (Gesamt + aktuelles Paket); Parser, XAML und Prozent-Auswertung getestet
- 1.7.0: Seite „Windows-Tweaks“ (50 Punkte inkl. 5 gemeinsamer RDS-Punkte und 6 einmaliger Aktionen), Geltungsbereich Benutzer/Standardprofil/rechnerweit, Wiederherstellungspunkt, Explorer-Neustart
- Getestet 1.7.0 (Standardbenutzer, Win 11 26H2 Notebook): Parser/BOM/XAML, OS-Erkennung, Katalog-Konsistenz (Ids eindeutig, auch gegenüber RDS), Status aller Punkte in den Bereichen „Benutzer“ und „rechnerweit“, Seite ohne Anzeige (Filter, Bereich, Geltungsbereich, Auswahl, Seitenwechsel), Anwenden/Rückgängig HKCU (Dateiendungen, Kontextmenü, „Task beenden“) und Testschlüssel mit Binär/Zeichenfolge/Standardwert – Registry danach identisch, neu angelegte Schlüssel entfernt; Standardprofil-Angaben und Ergänzen fehlender Ausgangswerte (ohne Hive-Laden)
- 1.8.0: Seite „Windows Update“ (Verfügbar/Installiert/Sicherheitslücken), Worker-Prozesse für Suche, Installation, CVE-Abgleich (MSRC Security Update Guide)
- Getestet 1.8.0 (Standardbenutzer, Win 11 26H2): Parser/BOM/XAML; echte Suche über Worker + Timer-Logik (25–34 s, 5 Updates, 504 Verlaufseinträge ohne Store-Apps, 43 Fehlschläge mit Fehlertext); CVE-Abgleich echt: eigenes System aktuell (0 offen, 3 s), simuliert älterer Build 1007 offen (KB5127648, 25 kritisch, 1 ausgenutzt, deutsche Titel), unbekanntes Produkt erkannt, Windows 10 22H2/1607 und Server 2016 Core; Reiter, Filter, Zähler, Zusammenfassung, Detail-Knöpfe ohne Anzeige geprüft; Installations-Worker nur Fehlerweg (unbekannte Update-Id); keine Temp-Reste
- 1.8.1: Startaufgabe „Cache-Laufwerk vorbereiten“ (Ordner + Rechte auf neuer Cache-Platte, Dienste neu starten), CD-ROM-Hinweis, MCSIO-Text, Sysprep-Hinweis
- Getestet 1.8.1 (Standardbenutzer): Parser Hauptskript und erzeugtes Startskript; Startskript-Fehlerweg (Laufwerk fehlt → nach 3 min Code 1, Protokoll mit Umlauten)
- 1.8.2: Office-Erkennung (Karte), Punkt Shared Computer Activation, SCA-Abfrage beim Versiegeln, Versiegeln-Schritt „Microsoft-365-Lizenzreste entfernen“
- Getestet 1.8.2 (Standardbenutzer, M365 Apps Current Channel ohne SCA): Parser/BOM; Get-OfficeInfo (Produkt, Kanal, Lizenzart, SCA nein); Punkt „Nicht zutreffend“ ohne RDSH/PVS/MCS, mit simuliertem PVS „Offen“; Versiegeln-Plan (-PlanOnly) mit neuem Schritt und SCA-Warnung; /dstatus-Parser an echter Ausgabe (Grace-Schlüssel entfernen, OneNote-Free behalten)

## Offen / mögliche Erweiterungen
- 1.8.2 als Admin auf Master mit M365 Apps: SCA-Abfrage beim Versiegeln → Werte gesetzt, rückgängig über die Seite; Lizenzreste entfernt (Ordner, Identität, Grace-Schlüssel); Klon: Benutzeranmeldung aktiviert per SCA (Token in %LOCALAPPDATA%\Microsoft\Office\16.0\Licensing)
- 1.8.1 als Admin auf PVS-/MCSIO-Test-VM: Punkt anwenden (Aufgabe, Skript, Ordner-ACL), Klon mit neuer Cache-Platte starten → Ordner/Rechte vorhanden, Ereignisprotokolle auf D: beschrieben, Spooler druckt; rückgängig entfernt Aufgabe und Skript
- 1.8.0 als Admin: Update installieren (Defender-Definition, Treiber einzeln, „Wichtige“ mit kumulativem Update), Abbrechen während des Laufs, Neustart-Angebot, Schließen während der Installation; WSUS-System (nur freigegebene Updates, Quelle-Karte); Server 2016–2025 und Server Core (Produktname, Suche); Proxy-Umgebung für die CVE-Abfrage
- Mögliche Erweiterung Windows Update: Updates ausblenden/einblenden, Download-Prozent (WUA-Callbacks)
- 1.7.0 als Admin: HKLM-Tweaks anwenden/rückgängig (z. B. Werbe-ID, lange Pfade, SMB1, Teredo); Geltungsbereich „+ Standardprofil“ (Hive lädt/entlädt, neuer Testbenutzer übernimmt z. B. Dateiendungen); Wiederherstellungspunkt mit eingeschaltetem Computerschutz (auf dem Entwicklungsrechner ist er aus); einmalige Aktionen (Temp, Update-Cache, DISM-Fenster, Widgets/Copilot entfernen, OneDrive); Explorer-Neustart auf RDS-Host nur in der eigenen Sitzung; Server 2016–2025
- Mögliche Erweiterung: Auswahl vorinstallierter Store-Apps zum Entfernen (Bloatware-Liste)
- 1.6.2 als Admin: Balken während echter Updates prüfen (liefert winget bei umgeleiteter Ausgabe Download-Prozent?)
- 1.6.0 als Admin: erneut ein Paket aktualisieren (Neu-Prüfen danach ohne Fehler?), „Alle Updates“ aktualisieren, „Abbrechen“ während des Laufs, Fenster schließen während des Laufs; winget auf Server 2022/2025 (Verfügbarkeit, Systemkontext)
- 1.5.0 als Admin auf RDS-Host: Eintrag ausblenden, einen nur für Testgruppe freigeben, mit Testbenutzern prüfen (Startmenü-Cache, Server 2016/2019/2022)
- 1.4.0 mit Adminrechten auf Test-VM/Master-Image: Umleitung (Ereignisprotokolle, Spooler, Auslagerungsdatei, WEM-Cache) anwenden → Neustart → rückgängig; „Versiegeln und herunterfahren“ komplett (inkl. Herunterfahren; Office-Rearm auf Master mit Office-Volumenlizenz, Klon aktiviert am KMS); bcdedit-/RSS-Punkte; RDS-Kulanzfrist auf RD-Sitzungshost (vorher/nachher GracePeriod, Besitzer wieder NETWORK SERVICE)
- RDS-Optimierung mit Adminrechten testen: je ein Punkt Registry/Aufgabe/Dienst/System anwenden und rückgängig machen
- Erkennung WEM/PVS/MCS auf echten Citrix-Systemen prüfen (Dienstnamen MCS, `Personality.ini`-Schlüssel `WriteCacheType`)
- Geplante Aufgaben allgemein (außer RDS-Liste) nicht im Umfang
- Test mit Administratorrechten durch den Nutzer: HKLM-Schalter, Dienst-Starttyp ändern/wiederherstellen
- Nutzer: auf dem betroffenen Rechner „Endgültig deaktivieren“ ausführen und nach Neuanmeldung prüfen
- Taskleistensymbol beim Start über die .cmd prüfen (per Screenshot nicht prüfbar)
- RDS-Einstufung auf einem echten Citrix-Server-VDA gegenprüfen
