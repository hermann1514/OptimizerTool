# Changelog

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
