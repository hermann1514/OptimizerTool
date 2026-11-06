# Aktueller Stand

## Erledigt
- Erfassung Registry Run (HKCU, HKLM, HKLM 32-Bit) und Autostart-Ordner (Benutzer, alle)
- Einzelnes De-/Aktivieren über StartupApproved (wie Task-Manager), Adminprüfung + Neustart mit Rechten
- Systeminformationen (OS, Rechner, CPU, RAM, Grafik, Datenträger, Netzwerk), Kopieren als Text
- Sicherung (JSON + .reg), Wiederherstellung mit Vorschau, automatische Sicherungen
- Protokoll pro Tag, Anzeige im Tool
- Getestet: Rendering aller Seiten, Schalter-Klick → Registry/Protokoll/Sicherung, Restore-Plan
- 1.1.0: Seite „Dienste“ (Starttyp ändern, Citrix-RDS-Einstufung), Sicherung v2 mit Dienst-Starttypen
- Getestet (Standardbenutzer): Erfassung ~300 Dienste, Rendering/Filter, Restore-Plan v1/v2, Fehlerpfad sc.exe (Code 5)

- Rückmeldung „Run-Eintrag bleibt nach Deaktivieren“: gewolltes Verhalten (StartupApproved), jetzt in Status/Tooltip/README erklärt

## Offen / mögliche Erweiterungen
- Geplante Aufgaben (nicht im Umfang)
- Test mit Administratorrechten durch den Nutzer: HKLM-Schalter und Dienst-Starttyp ändern/wiederherstellen
- RDS-Einstufung (~300 Regeln, alle Inbox-Dienste) auf einem echten Citrix-Server-VDA gegenprüfen (dort andere Dienste als auf diesem Win11-Testrechner)
