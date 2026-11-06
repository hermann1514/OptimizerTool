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

## Offen / mögliche Erweiterungen
- 1.4.0 mit Adminrechten auf Test-VM/Master-Image: Umleitung (Ereignisprotokolle, Spooler, Auslagerungsdatei, WEM-Cache) anwenden → Neustart → rückgängig; „Versiegeln und herunterfahren“ komplett (inkl. Herunterfahren); bcdedit-/RSS-Punkte; RDS-Kulanzfrist auf RD-Sitzungshost (vorher/nachher GracePeriod, Besitzer wieder NETWORK SERVICE)
- RDS-Optimierung mit Adminrechten testen: je ein Punkt Registry/Aufgabe/Dienst/System anwenden und rückgängig machen
- Erkennung WEM/PVS/MCS auf echten Citrix-Systemen prüfen (Dienstnamen MCS, `Personality.ini`-Schlüssel `WriteCacheType`)
- Prüfen, ob die ~85 „Deaktivierbar“-Dienste vorausgewählt bleiben sollen
- Geplante Aufgaben allgemein (außer RDS-Liste) nicht im Umfang
- Test mit Administratorrechten durch den Nutzer: HKLM-Schalter, Dienst-Starttyp ändern/wiederherstellen
- Nutzer: auf dem betroffenen Rechner „Endgültig deaktivieren“ ausführen und nach Neuanmeldung prüfen
- Taskleistensymbol beim Start über die .cmd prüfen (per Screenshot nicht prüfbar)
- RDS-Einstufung auf einem echten Citrix-Server-VDA gegenprüfen
