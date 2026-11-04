# Lernstand je Modul

`cases.json` beschreibt, welchen Lernstand (0–100) ein Modul aus seinen Wochentests, Karteikarten und Aufgaben des
Lernplans bekommt. Die Formel steht in `docs/LERNSTAND-2026-11-04.md`. Eine Fassung für PC und iPad:

| Seite | Umsetzung | Geprüft von |
| --- | --- | --- |
| Python | `app/mastery.py` (`compute`, `for_module`) | `tests/test_mastery.py` |
| iPad | `Mastery` in `apps/apple/Packages/UniFlowCore/Sources/UniFlowCore/LocalBackend/Study/Mastery.swift` | `MasteryTests` |
| Web (Beschriftung) | `app/static/mastery.js` | `tests/js/mastery.test.mjs` |
| iPad-App (Beschriftung) | `LernstandText` in `apps/apple/UniFlow/Views/Modules/LernstandView.swift` | `LernstandAppTests` |

- `input.tests`: Paare `[Punkte, Höchstpunkte]` der abgegebenen Wochentests, älteste zuerst.
- `input.cards_right` / `cards_wrong`: Karteikarten des Moduls nach dem letzten Urteil (`last_result`).
- `input.tasks_done` / `tasks_total`: Aufgaben des Lernplans für das Modul (erledigt / alle).
- `expected`: das Feld `mastery` der Antwort (`null` = noch kein Lernstand), `label` die Beschriftung der Karten.

Die Erwartungen sind von Hand nachgerechnet. Ändert sich die Formel, beide Umsetzungen gleich ändern und die Fälle hier
anpassen. Nur erfundene Zahlen.
