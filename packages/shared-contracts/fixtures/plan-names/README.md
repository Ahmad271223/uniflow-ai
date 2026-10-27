# Kurznamen enger Kalenderblöcke

`cases.json` beschreibt, welchen Kurznamen ein Block im Lernkalender bekommt, wenn er eng ist (Woche auf dem iPad,
mehrere Termine nebeneinander). Eine Fassung für Web und iPad:

| Seite | Umsetzung | Geprüft von |
| --- | --- | --- |
| Web | `app/static/plan-names.js` | `tests/test_plan_names.py` (node oder, auf dem Mac, JavaScriptCore) |
| iPad | `PlanNames` in `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/LocalBackend/Study/PlanNames.swift` | `PlanNamesTests` |

- `single`: ein Titel allein (`tinyName`).
- `plans`: alle Titel eines Plans mit Modul-ID (`tinyNames`); verschiedene Fächer bekommen verschiedene Kurznamen.

Die Erwartungen sind von Hand geprüft. Ändert sich das Verfahren, beide Umsetzungen gleich ändern und die Fälle hier
anpassen. Nur erfundene Fächer oder allgemeine Fachtitel, keine echten Kurs-IDs oder Räume.
