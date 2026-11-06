# Projektkontext: Windows-Optimizer (vormals Autostart-Manager)

Portables Windows-Tool (ohne Installation) zum Anzeigen und einzelnen De-/Aktivieren von Autostart-Programmen
und Windows-Diensten, dazu Systeminformationen, Sicherung/Wiederherstellung und Protokoll.

## Dateien
| Datei | Zweck |
|---|---|
| `Start-WindowsOptimizer.cmd` | Starter (Doppelklick), ruft PowerShell mit `-STA -ExecutionPolicy Bypass -WindowStyle Hidden` auf |
| `WindowsOptimizer.ps1` | Gesamte Logik + UI-Verdrahtung (Regionen: Ablage/Protokoll, Registry, Erfassung, Dienste, Sicherung, Systeminfo, Oberfläche, Start) |
| `MainWindow.xaml` | WPF-Oberfläche (Styles, 7 Seiten: Autostart, Dienste, RDS-Optimierung, Startmenü, System, Sicherung, Protokoll) |
| `logs\`, `backups\` | Werden zur Laufzeit neben dem Skript angelegt; falls nicht beschreibbar unter `%LOCALAPPDATA%\WindowsOptimizer` |

App-Symbol wird zur Laufzeit gezeichnet (`New-AppIcon`, keine Datei). `Set-AppUserModelId 'WindowsOptimizer'` sorgt für eine eigene Taskleistengruppe statt PowerShell.

## Autostart: Quellen und Deaktivierung (siehe DECISIONS.md)
Quellen: HKCU Run, HKLM Run, HKLM WOW6432Node Run, Startordner Benutzer, Startordner alle.
Deaktivieren = Verschieben in die Ablage `WindowsOptimizerDisabled` (`$script:StoreName`):
- Registry: Unterschlüssel `<Run>\WindowsOptimizerDisabled` (Wert, Typ, Rohtext unverändert; `Move-RunValue`, erst schreiben, dann löschen)
- Ordner: Unterordner `<Startup>\WindowsOptimizerDisabled` (`Move-StartupFile`)
Eintrag-Id `SourceId|ValueName` ist in Run und Ablage gleich. Steht ein Name in beiden, gilt der aktive Eintrag (Ablagekopie ausgeblendet, beim Einschalten verworfen).
StartupApproved (Task-Manager, REG_BINARY Byte 0: 02 an / 03 aus) wird nur noch gelesen: Einträge in Run mit 03 = `ApprovedOff` („nur Task-Manager-Sperre“), Button `BtnFixApproved` verschiebt sie. Beim Einschalten wird 03 auf 02 gesetzt.
HKLM-Einträge/Startordner alle nur mit Adminrechten änderbar.

## Dienste
Region „Dienste“ im Skript. Liste aus `Win32_Service`, Starttyp aus `HKLM\SYSTEM\CurrentControlSet\Services\<Name>` (`Start`, `DelayedAutostart`, `Type`).
Ändern per `sc.exe config <Name> start= auto|delayed-auto|demand|disabled` (nur Admin), danach erneutes Lesen zur Kontrolle. Benutzerdienst-Instanzen (`Type & 0x80`) nicht änderbar.
Citrix-RDS-Einstufung: statische Tabelle `$script:RdsHints` (Name/Platzhalter → Benötigt | Belassen | Prüfen | Deaktivierbar). Ohne Regel (`Get-RdsHint`): Name/Anzeigename mit update/updater/elevation/maintenance → Prüfen; Hersteller Microsoft bzw. Datei unter `%SystemRoot%` → Belassen; sonst Drittanbieter (Hersteller aus FileVersionInfo).

## RDS-Optimierung
Region „RDS-Optimierung“. `Get-CitrixEnvironment` erkennt VDA (+ Version), WEM (+ Cache-Ort), PVS (installiert: `BNDevice`/`bnistack`; von vDisk gestartet: Schlüssel `bnistack\PVSAgent`, Modus aus `WriteCacheType`), MCS (installiert: Dienste; bereitgestellt: `Personality.ini` ohne PVSAgent, `DiskMode`; MCSIO ab VDA 7.21), Plattform/VMware und Server 2019.
Typen: Registry (auch `Kind='Key'` = Schlüsselexistenz), Task, Service, System (Skriptblöcke Test/Read/Apply/Undo), Hint.
Versiegeln: einmalige Schritte in `Get-SealSteps` (optional `Check` = Grund fürs Überspringen, z. B. Office-Rearm nur bei Volumenlizenz über `Find-OfficeOspp`/`Get-OfficeLicenseStatus`), gesammelt ausgeführt über Button `BtnSeal` → `Invoke-SealAndShutdown` (Plan via `Get-SealPlan`, Rückfrage, Sicherung, Schritte, `seal:last`, `shutdown /s /t 5`). Optionale `Prepare`/`After`-Blöcke (z. B. Zielordner anlegen, WEM-Cache aktualisieren). Cache-Laufwerk: `$script:OptCacheDrive` (Auswahl `CmbOptCacheDrive`), Bedingung `CacheDisk` = PVS oder MCSIO und Laufwerk gewählt.
`Get-OptimizationCatalog` liefert Hashtables (Id, Group, Category, Kind = Registry | Task | Service | System | Hint, Level, Applies = All | PVS | MCS | Image | WEM | WEMImage) plus dynamisch alle installierten `$script:RdsHints`-Dienste mit „Deaktivierbar“.
Status über `Get-OptStatus`; geplante Aufgaben einmal pro Prüfung gecacht (`Update-OptTaskCache`, Einzelabfrage ~2 s).
Undo: `backups\rdsopt_original.json`, Originalzustand je Id nur beim ersten Anwenden (siehe DECISIONS.md). Dienste über `Set-ServiceStartType`.

## Startmenü
Region „Startmenü“. `Get-StartMenuEntries` liest `CommonPrograms` (rekursiv `.lnk/.url/.appref-ms`, relativer Pfad über `Get-SmFiles`) und die Ablage `$script:SmStore`, Status über `Get-SmAclInfo` (Alle / Eingeschränkt + Gruppen); Store-Apps über `Get-AppxPackage` (nur Anzeige). Ändern: `Set-StartMenuVisibility` (show | hide | groups), Gruppen via `Resolve-SmGroups`, Ursprungs-SDDL in `backups\startmenu_original.json` (siehe DECISIONS.md).

## Sicherung
`backups\autostart_<Datum>_<Zeit>.json` (Format `WindowsOptimizer-Backup`, alt `AutostartManager-Backup` wird weiter gelesen; Zustand + Befehl/Verknüpfungsziel je Eintrag; ab Version 2 zusätzlich `Services` = Name/StartType) und `.reg`-Export der Run-Schlüssel (inkl. Ablage-Unterschlüssel) und StartupApproved.
Wiederherstellung: schaltet über `Set-EntryState` (verschieben), legt fehlende Run-Werte/Verknüpfungen neu an (aktiv → Run/Ordner, deaktiviert → Ablage); neue Einträge bleiben unberührt.
Automatische Sicherung vor der ersten Änderung pro Sitzung und vor jeder Wiederherstellung.

## Protokoll
`logs\autostart_<yyyyMMdd>.log`, UTF-8, eine Zeile je Aktion.
