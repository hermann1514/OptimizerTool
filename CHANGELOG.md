# Changelog

## 1.1.0 – 2026-11-06
- Neue Seite „Dienste“: Windows-Dienste mit Suche, Filter (Automatisch/Manuell/Deaktiviert), Starttyp änderbar per Auswahl (sc.exe)
- Spalte „Citrix RDS“: Einstufung Benötigt / Belassen / Prüfen / Deaktivierbar / Drittanbieter mit Begründung (~300 Regeln nach Citrix Optimizer, Microsoft WDOT und Microsoft-Dienstempfehlungen; unbekannte Dienste per Hersteller/Programmdatei eingeordnet); Rückfrage beim Deaktivieren benötigter Dienste
- Sicherung Format-Version 2: enthält zusätzlich Dienst-Starttypen; Wiederherstellung setzt sie zurück (v1-Sicherungen weiter nutzbar)
- README.md mit Funktionsbeschreibung und Bedienungsanleitung

## 1.0.0 – 2026-11-04
- Erste Version: Autostart-Manager als portables PowerShell/WPF-Tool
- Autostart-Liste mit Suche, Filter, Schalter je Eintrag, „Anzeigen“ im Explorer
- Systeminformationen, Sicherung/Wiederherstellung, Protokoll
