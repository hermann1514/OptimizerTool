# Entscheidungen

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
