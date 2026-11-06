# Entscheidungen

## 2026-11-06 – BIS-F als Quelle: nur Fakten übernehmen, keinen Code
**Kontext:** BIS-F (Base Image Script Framework) enthält viele bewährte Image-Optimierungen, steht aber unter GPL-3.0.
**Entscheidung:** Übernommen werden nur Einstellungen, Registry-Werte, Erkennungsmerkmale und Befehle; die Umsetzung ist eigener Code im Katalog-Stil des Projekts. Nicht übernommen: DEP aus (Sicherheit), DHCP-Werte leeren (veralteter Workaround), ngen (blockiert die Oberfläche), Drittanbieter-Tools.
**Folgen:** Projektlizenz bleibt unabhängig von BIS-F.
**Ergänzung 06.11.2026:** „RDS-Kulanzfrist zurücksetzen“ wurde zunächst ausgelassen, auf Nutzerentscheidung aber als Versiegeln-Schritt aufgenommen (mit dem Hersteller abgestimmter Image-Workaround). Abweichend von BIS-F werden Besitzer und Rechte des GracePeriod-Schlüssels danach wiederhergestellt; Hinweis im Tool: ersetzt keine RDS-CALs.

## 2026-11-06 – „Versiegeln“ als bewusste Ausnahme vom Undo-Prinzip
**Kontext:** Aufräumschritte vor dem Verteilen eines Images (Kennungen, Caches, Ereignisprotokolle) lassen sich naturgemäß nicht umkehren.
**Entscheidung:** Nicht als einzelne Punkte in der Optimierungsliste, sondern gesammelt über den Button „Versiegeln und herunterfahren“ (`Get-SealSteps`, `Invoke-SealAndShutdown`), weil sie bei jeder Image-Aktualisierung immer vollständig nötig sind. Vorher Liste der auszuführenden und übersprungenen Schritte mit Rückfrage, automatische Sicherung; nur Zeitpunkt des letzten Laufs gespeichert (`seal:last` in `rdsopt_original.json`). Bei Fehlern zweite Rückfrage vor dem Herunterfahren.

## 2026-11-06 – RDS-Optimierung: Undo je Punkt über eigene Ablage
**Kontext:** Optimierungen (Registry, Aufgaben, Dienste, powercfg) sollen einzeln rückgängig machbar sein, auch nach Neustart des Tools.
**Entscheidung:** Beim ersten Anwenden eines Punkts wird dessen Ausgangszustand in `backups\rdsopt_original.json` geschrieben (Registry: Wert, Typ oder „fehlte“; Aufgabe an/aus; Starttyp; powercfg-Wert). Erneutes Anwenden überschreibt ihn nicht; „Rückgängig“ stellt ihn her und entfernt den Eintrag. Zusätzlich `.reg`-Export der betroffenen Schlüssel und die normale Sitzungssicherung.
**Folgen:** Nicht umkehrbare Maßnahmen (z. B. Apps entfernen) bleiben außen vor. Nicht in der JSON-Sicherung/Wiederherstellung der Seite „Sicherung“ enthalten (außer Dienst-Starttypen).

## 2026-11-06 – Autostart deaktivieren durch Verschieben statt StartupApproved
**Kontext:** Bis 1.1.0 wurde wie im Task-Manager nur `…\Explorer\StartupApproved` auf „aus“ gesetzt. In der Praxis starteten so gesperrte Programme beim Nutzer trotzdem (Sperre wird nicht von allen Programmen/Startwegen beachtet bzw. von Programmen zurückgesetzt).
**Entscheidung:** Deaktivieren verschiebt den Eintrag in eine Ablage, die Windows nicht auswertet (Prinzip Sysinternals Autoruns):
- Registry: `<Run>\WindowsOptimizerDisabled` (Unterschlüssel)
- Autostart-Ordner: `<Startup>\WindowsOptimizerDisabled` (Unterordner)
Aktivieren schreibt Name, Typ und Rohtext unverändert zurück und hebt eine evtl. StartupApproved-Sperre auf. Nichts wird endgültig gelöscht; Reihenfolge immer „erst schreiben, dann löschen“.
**Folgen:**
- Ausgeschaltete Einträge erscheinen nicht mehr im Task-Manager.
- Alte StartupApproved-Sperren werden erkannt („nur Task-Manager-Sperre“) und per Button in die Ablage überführt.
- Programme, die sich selbst neu in Run eintragen, erscheinen wieder als aktiv; der aktive Eintrag gewinnt, die Ablagekopie wird beim Einschalten verworfen.
- Sicherungen bleiben kompatibel (Id `SourceId|ValueName` unverändert).
