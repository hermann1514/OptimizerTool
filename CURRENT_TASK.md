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

## Offen / mögliche Erweiterungen
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
