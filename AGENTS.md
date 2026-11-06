# Arbeitsregeln

Lies zu Beginn jeder Aufgabe zuerst:
- PROJECT_CONTEXT.md
- CURRENT_TASK.md
- CHANGELOG.md
- DECISIONS.md, falls Architektur relevant ist

Nutze danach nur die für die Aufgabe relevanten Dateien.

Projektspezifisch:
- Keine Installation, keine externen Abhängigkeiten: nur PowerShell 5.1 + WPF (.NET Framework 4.x).
- `WindowsOptimizer.ps1` muss als **UTF-8 mit BOM** gespeichert sein (sonst zeigt PowerShell 5.1 Umlaute falsch an).
- Autostart-Einträge nie endgültig löschen; Deaktivieren = Verschieben in die Ablage `WindowsOptimizerDisabled` (Unterschlüssel von Run bzw. Unterordner des Autostart-Ordners), Aktivieren = unverändert zurückschreiben. Siehe DECISIONS.md.
