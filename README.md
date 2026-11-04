# Autostart-Manager

Ein kleines, portables Windows-Werkzeug, das alle Programme anzeigt, die bei der Anmeldung automatisch starten. Jedes Programm lässt sich einzeln aus- und wieder einschalten.
Dazu kommen eine Übersicht der Systeminformationen, eine Sicherung mit Wiederherstellung und ein Protokoll aller Änderungen.

**Keine Installation nötig.** Das Tool nutzt nur PowerShell und WPF, beides ist in Windows bereits enthalten.

---

## Funktionen

- **Autostart-Liste**: zeigt Programme aus folgenden Quellen:
  - Registry `Run` des aktuellen Benutzers (HKCU)
  - Registry `Run` für alle Benutzer (HKLM, auch 32-Bit)
  - Autostart-Ordner des Benutzers und für alle Benutzer
- **Ein-/Ausschalten pro Programm** per Schalter. Es wird nichts gelöscht.
- **Zusatzinfos je Eintrag**: Herausgeber, Programmbeschreibung, vollständiger Befehl, Quelle, Hinweis *„Datei fehlt“* bei verwaisten Einträgen.
- **Suche und Filter** (Alle / Aktiv / Deaktiviert), Sortierung per Klick auf die Spaltenköpfe.
- **„Anzeigen“** öffnet den Speicherort der Programmdatei im Explorer.
- **Systeminformationen**: Betriebssystem, Rechner/BIOS, Prozessor, Arbeitsspeicher, Grafik, Datenträger, Netzwerk. Mit einem Klick als Text kopierbar.
- **Sicherung und Wiederherstellung** des Autostart-Zustands, mit Vorschau vor dem Zurückspielen.
- **Protokoll**: jede Änderung mit Zeitpunkt, eine Datei pro Tag.

## Voraussetzungen

- Windows 10 oder Windows 11
- Windows PowerShell 5.1 (ab Werk vorhanden)
- Für Einträge *aller Benutzer* (HKLM): Administratorrechte

## Start

1. Projekt herunterladen: auf GitHub über **Code → Download ZIP**, oder per Git:
   ```
   git clone https://github.com/hermann1514/OptimizerTool.git
   ```
2. Bei einer ZIP-Datei: vor dem Entpacken **Rechtsklick → Eigenschaften → „Zulassen“** anhaken. Sonst warnt Windows beim Start, weil die Datei aus dem Internet stammt.
3. **`Start-AutostartManager.cmd`** doppelklicken.

Der Ordner kann überall liegen, auch auf einem USB-Stick. Die Dateien `Start-AutostartManager.cmd`, `AutostartManager.ps1` und `MainWindow.xaml` müssen im selben Ordner bleiben.

## Bedienung

### Autostart

| Element | Bedeutung |
|---|---|
| Schalter links | an = startet bei der Anmeldung, aus = startet nicht mehr |
| Ausgegrauter Schalter | Eintrag für alle Benutzer, nur mit Adminrechten änderbar |
| Quelle | Woher der Eintrag stammt (`HKCU Run`, `HKLM Run`, `Startordner` …). Beim Darüberfahren erscheint der genaue Pfad. |
| Datei fehlt | Die Programmdatei existiert nicht mehr, der Eintrag ist vermutlich ein Überbleibsel |
| Neu einlesen | Liste aktualisieren, z. B. nach einer Programminstallation |

Änderungen gelten ab der **nächsten Anmeldung**. Bereits laufende Programme werden nicht beendet.

### Administratorrechte

Ohne Adminrechte werden alle Einträge angezeigt, aber nur die des eigenen Benutzers lassen sich schalten.
Über **„Als Administrator starten“** unten in der Seitenleiste startet das Tool neu mit erhöhten Rechten. Danach sind auch die Einträge für alle Benutzer änderbar.

### System

Zeigt die wichtigsten Daten des Rechners. Füllbalken zeigen die Belegung von RAM, Datenträgern und Prozessor. Ab 75 % werden sie orange, ab 90 % rot.
**„Als Text kopieren“** legt alles in die Zwischenablage, z. B. für eine Support-Anfrage.

### Sicherung

- **Sicherung erstellen**: speichert, welche Einträge gerade aktiv oder deaktiviert sind.
- **Wiederherstellen**: setzt den Zustand einer ausgewählten Sicherung zurück. Vorher erscheint eine Liste der geplanten Änderungen zur Bestätigung. Einträge, die seit der Sicherung gelöscht wurden, werden wieder angelegt, soweit möglich. Neu hinzugekommene Einträge bleiben unverändert.
- **Löschen**: entfernt die ausgewählte Sicherung.

Automatische Sicherungen entstehen
- vor der **ersten Änderung** in jeder Sitzung und
- vor jeder **Wiederherstellung**.

Zu jeder Sicherung gibt es zusätzlich eine `.reg`-Datei mit den betroffenen Registry-Schlüsseln. Im Notfall lässt sie sich auch ohne das Tool per Doppelklick einspielen.

### Protokoll

Zeigt alle Aktionen des gewählten Tages, die neueste steht oben. Ein Beispiel:

```
2026-11-04 22:42:11  INFO   SICHERUNG   autostart_20261104_224210.json (21 Einträge, Anlass: Automatisch (vor erster Änderung))
2026-11-04 22:42:11  INFO   DEAKTIVIERT OneDrive  [HKCU Run]  "C:\Program Files\Microsoft OneDrive\OneDrive.exe" /background
```

## So funktioniert das Ausschalten

Das Tool arbeitet genauso wie der **Autostart-Reiter im Task-Manager**. Es setzt für den Eintrag einen Schalter unter

```
...\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\{Run | Run32 | StartupFolder}
```

Der ursprüngliche Autostart-Eintrag bleibt unverändert. Deshalb gilt:

- Ausschalten lässt sich jederzeit rückgängig machen.
- Der Task-Manager zeigt denselben Zustand an, und umgekehrt.
- Wird das Programm später deinstalliert, verschwindet sein Eintrag ganz normal.

## Speicherorte

| Daten | Ort |
|---|---|
| Sicherungen | `backups\` neben dem Skript |
| Protokolle | `logs\` neben dem Skript |

Ist der Programmordner schreibgeschützt (z. B. unter `C:\Programme`), verwendet das Tool stattdessen `%LOCALAPPDATA%\AutostartManager\`.

## Dateien

| Datei | Zweck |
|---|---|
| `Start-AutostartManager.cmd` | Starter (Doppelklick) |
| `AutostartManager.ps1` | Programmlogik |
| `MainWindow.xaml` | Oberfläche |

## Grenzen

- Geplante Aufgaben und Windows-Dienste werden nicht angezeigt.
- Dateien im Autostart-Ordner, die keine Verknüpfung (`.lnk`) sind, kann die Wiederherstellung nicht neu erzeugen, wenn sie gelöscht wurden. Ihr An/Aus-Zustand wird trotzdem wiederhergestellt.
- Wer den Admin-Neustart mit einem **anderen** Administratorkonto bestätigt, sieht unter „Benutzer“ dessen Einträge statt der eigenen.

## Fehlerbehebung

| Problem | Lösung |
|---|---|
| Doppelklick auf die `.cmd` tut nichts | Prüfen, ob alle drei Dateien im selben Ordner liegen; ZIP vorher „zulassen“ (siehe *Start*) |
| Umlaute werden falsch angezeigt | `AutostartManager.ps1` muss als **UTF-8 mit BOM** gespeichert sein |
| Schalter lässt sich nicht bewegen | Eintrag gehört zu „Alle Benutzer“: **Als Administrator starten** |
| Fehlermeldung beim Start | Details stehen im Protokoll unter `logs\` |
