# Aktueller Stand

Verlauf der Versionen und Tests: CHANGELOG.md und Git-Historie. Hier steht nur, was gerade gilt und was offen ist.

Regeln: Das Repo ist öffentlich, also keine Benutzer-, Rechner- oder Domänennamen und kein `docs/` committen (ignoriert). Jeder Push auf `main` ist sofort ein Update für alle Kopien.

## Übergabe (Stand 26.11.2026, Version 1.18.5) – hier weitermachen
1. Am Master in der Wartungsversion: „Nach Updates suchen“ → 1.18.5.
2. `redir.bootprep` und `sys.pvspreload` einmal anwenden, damit die Startskripte neu geschrieben werden. Ab 1.18.4 bleiben sie auch nach Updates „Umgesetzt“.
3. Versiegeln und im Protokoll prüfen:
   - „Dienst MSDTC gestoppt“, danach steht `seal.msdtc` auf OK. Der Stopp ist lokal nicht getestet.
   - SentinelOne: „mit VDI-Option installiert – … kein Zurücksetzen nötig“.
4. Am Target „Status kopieren“. Erwartet ist nur noch offen:
   - `reg.machinepwd`, das per GPO vorgegeben ist.
   - Die nicht angewendeten Punkte der Stufe „Prüfen“.
   - Oben steht der Hinweis „Keine Sicherung im Programmordner“. Das ist erwartet, weil nur am Master angewendet wird.
5. In der S1-Konsole: Jeder Klon meldet sich mit eigener UID. Inaktive Endpunkte automatisch aufräumen lassen.

## Geltende Befunde
- **`reg.machinepwd`:** Die Default Domain Policy, die zusätzlich an der Citrix-OU verknüpft ist, setzt „Domänenmitglied: Änderungen von Computerkontenkennwörtern deaktivieren“ auf „Deaktiviert“. Abhilfe in der GPO-Struktur bzw. bei der PVS-Kennwortverwaltung, nicht im Tool. Andere offene Punkte setzt keine GPO.
- **`NtfsDisableLastAccessUpdate`:** Windows schreibt den Wert beim Start um. `0x80000003` gilt als „aus“, der Punkt prüft bitweise (1.18.3).
- **SentinelOne:**
  - Der Agent ist mit `/vdi` installiert, deshalb ist kein UUID-Reset beim Versiegeln nötig (DECISIONS.md).
  - Die Kanäle `SentinelOne/*` bleiben bewusst bei 1 GB (Entscheidung des Nutzers).
- **Geschützte Dienste (Code 5, auch als Admin):** `embeddedmode`, `NgcSvc` und `NgcCtnrSvc` stehen auf „Belassen“.
- **IPv6:** Bleibt auf „Prüfen“. Microsoft rät vom Abschalten ab (KB 929852). PVS streamt nur über IPv4.
- **`svc.NcbService`:** Bleibt auf „Manuell“, weil `sys.svcdeps` ihn für CDPSvc braucht.
- **Startaufgaben** sind für Standardbenutzer nicht sichtbar. Ihren Status deshalb nur als Admin prüfen.

## Offen
- **Teams:** Am Target mit einem zweiten Benutzer prüfen. Kein `ms-teams.exe` und kein `Update.exe` im Autostart, `TeamsTfwStartupTask` mit State = 1. Prüfen, ob Teams startet, wenn der Benutzer den Autostart in Teams wieder einschaltet.
- **Anmeldung des zweiten Benutzers** (Desktop nach 31 s, Autostarts strikt nacheinander):
  - FSLogix 16,5 s: Containergröße und Protokoll prüfen (`C:\ProgramData\FSLogix\Logs`).
  - Smartcard-Starter 30 s: Er bleibt, Rückfrage bei Citrix.
  - SentinelUI 16 s: Tray-Symbol per S1-Richtlinie aus?
  - Danach `StartupDelayInMSec` entscheiden.
- **Acrobat:** Nach dem nächsten Update prüfen, ob `sys.adobecollab.file` wieder auf „Offen“ steht.
- **Online-Update:** Proxy-Umfeld und Server ohne Internet (Fehlermeldung). Ältere Kopien ohne Updater einmal von Hand aktualisieren.
- **Aus der Ereignisanalyse** (lokal in `docs/`), ohne Änderung am Tool:
  - Ursache des WSearch-Absturzes (Application 1000/1001)
  - SCHANNEL-Werte
  - VBS/Credential Guard auf XenServer
  - DNS-Registrierung mit dem Master-Namen (8036/8030)
  - Secure-Boot-Zertifikate 2023
  - PVS-Agent 7043
- **DNS-Server:** Alte A-Einträge löschen. Festlegen, wie Einträge entfernter VMs aufgeräumt werden (Löschen beim Entfernen, DHCP-Registrierung oder Scavenging).
- **Noch nicht als Admin bzw. auf echten Systemen getestet:**
  - Windows Update installieren (Server 2016–2025, WSUS)
  - winget-Updates
  - Startmenü-Freigaben mit Testgruppe
  - HKLM-Tweaks mit „+ Standardprofil“
  - BIS-F-Deinstallation
  - Neue leere Cache-Platte am PVS-Klon
- **Mögliche Erweiterungen:**
  - Geschützte Dienste allgemein erkennen (Sicherheitsbeschreibung des Dienstes), falls weitere auftauchen
  - Auswahl vorinstallierter Store-Apps zum Entfernen
  - Windows-Updates ausblenden, Download-Prozent anzeigen
  - NCPA beim Versiegeln aufräumen
  - RSoP-Anzeige: welche GPO einen Wert vorgibt
