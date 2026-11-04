# Projektkontext: Autostart-Manager

Portables Windows-Tool (ohne Installation) zum Anzeigen und einzelnen De-/Aktivieren von Autostart-Programmen,
dazu Systeminformationen, Sicherung/Wiederherstellung und Protokoll.

## Dateien
| Datei | Zweck |
|---|---|
| `Start-AutostartManager.cmd` | Starter (Doppelklick), ruft PowerShell mit `-STA -ExecutionPolicy Bypass` auf |
| `AutostartManager.ps1` | Gesamte Logik + UI-Verdrahtung (Regionen: Ablage/Protokoll, Registry, Erfassung, Sicherung, Systeminfo, Oberfläche, Start) |
| `MainWindow.xaml` | WPF-Oberfläche (Styles, 4 Seiten: Autostart, System, Sicherung, Protokoll) |
| `logs\`, `backups\` | Werden zur Laufzeit neben dem Skript angelegt; falls nicht beschreibbar unter `%LOCALAPPDATA%\AutostartManager` |

## Erfasste Quellen → StartupApproved-Schlüssel
- HKCU `...\CurrentVersion\Run` → HKCU `...\Explorer\StartupApproved\Run`
- HKLM `...\CurrentVersion\Run` → HKLM `...\StartupApproved\Run`
- HKLM `WOW6432Node\...\Run` → HKLM `...\StartupApproved\Run32`
- Startordner Benutzer → HKCU `...\StartupApproved\StartupFolder`
- Startordner alle → HKLM `...\StartupApproved\StartupFolder`

Wert = REG_BINARY 12 Byte: Byte 0 gerade (02) = aktiv, ungerade (03) = deaktiviert, Byte 4–11 FILETIME. Identisch zum Task-Manager.
HKLM-Einträge nur mit Adminrechten änderbar (Button „Als Administrator starten“).

## Sicherung
`backups\autostart_<Datum>_<Zeit>.json` (Zustand + Befehl/Verknüpfungsziel je Eintrag) und `.reg`-Export der Schlüssel.
Wiederherstellung: setzt Zustände zurück, legt fehlende Run-Werte/Verknüpfungen neu an; neue Einträge bleiben unberührt.
Automatische Sicherung vor der ersten Änderung pro Sitzung und vor jeder Wiederherstellung.

## Protokoll
`logs\autostart_<yyyyMMdd>.log`, UTF-8, eine Zeile je Aktion.
