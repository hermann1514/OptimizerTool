# Projektkontext: Autostart-Manager

Portables Windows-Tool (ohne Installation) zum Anzeigen und einzelnen De-/Aktivieren von Autostart-Programmen,
dazu Systeminformationen, Sicherung/Wiederherstellung und Protokoll.

## Dateien
| Datei | Zweck |
|---|---|
| `Start-AutostartManager.cmd` | Starter (Doppelklick), ruft PowerShell mit `-STA -ExecutionPolicy Bypass` auf |
| `AutostartManager.ps1` | Gesamte Logik + UI-Verdrahtung (Regionen: Ablage/Protokoll, Registry, Erfassung, Sicherung, Systeminfo, Oberfläche, Start) |
| `MainWindow.xaml` | WPF-Oberfläche (Styles, 5 Seiten: Autostart, Dienste, System, Sicherung, Protokoll) |
| `logs\`, `backups\` | Werden zur Laufzeit neben dem Skript angelegt; falls nicht beschreibbar unter `%LOCALAPPDATA%\AutostartManager` |

## Erfasste Quellen → StartupApproved-Schlüssel
- HKCU `...\CurrentVersion\Run` → HKCU `...\Explorer\StartupApproved\Run`
- HKLM `...\CurrentVersion\Run` → HKLM `...\StartupApproved\Run`
- HKLM `WOW6432Node\...\Run` → HKLM `...\StartupApproved\Run32`
- Startordner Benutzer → HKCU `...\StartupApproved\StartupFolder`
- Startordner alle → HKLM `...\StartupApproved\StartupFolder`

Wert = REG_BINARY 12 Byte: Byte 0 gerade (02) = aktiv, ungerade (03) = deaktiviert, Byte 4–11 FILETIME. Identisch zum Task-Manager.
HKLM-Einträge nur mit Adminrechten änderbar (Button „Als Administrator starten“).

## Dienste
Region „Dienste“ im Skript. Liste aus `Win32_Service`, Starttyp aus `HKLM\SYSTEM\CurrentControlSet\Services\<Name>` (`Start`, `DelayedAutostart`, `Type`).
Ändern per `sc.exe config <Name> start= auto|delayed-auto|demand|disabled` (nur Admin), danach erneutes Lesen zur Kontrolle. Benutzerdienst-Instanzen (`Type & 0x80`) nicht änderbar.
Citrix-RDS-Einstufung: statische Tabelle `$script:RdsHints` (Name/Platzhalter → Benötigt | Belassen | Prüfen | Deaktivierbar). Ohne Regel (`Get-RdsHint`): Name/Anzeigename mit update/updater/elevation/maintenance → Prüfen; Hersteller Microsoft bzw. Datei unter `%SystemRoot%` → Belassen; sonst Drittanbieter (Hersteller aus FileVersionInfo).

## Sicherung
`backups\autostart_<Datum>_<Zeit>.json` (Zustand + Befehl/Verknüpfungsziel je Eintrag; ab Version 2 zusätzlich `Services` = Name/StartType) und `.reg`-Export der Autostart-Schlüssel.
Wiederherstellung: setzt Zustände zurück, legt fehlende Run-Werte/Verknüpfungen neu an; neue Einträge bleiben unberührt.
Automatische Sicherung vor der ersten Änderung pro Sitzung und vor jeder Wiederherstellung.

## Protokoll
`logs\autostart_<yyyyMMdd>.log`, UTF-8, eine Zeile je Aktion.
