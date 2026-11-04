# Lernstand je Modul

Stand 04.11.2026. Wunsch des Inhabers: eine Zahl je Modul, die ehrlich zeigt, wie gut der Stoff sitzt – gut sichtbar,
motivierend, aber ohne Schönfärberei. Vorbild ist der „Mastery Score“ eines Mitbewerbers; bei StudiNow heißt er
**Lernstand** und wird **ohne KI, ohne neue Tabellen** aus dem berechnet, was die App ohnehin speichert.

## Formel (eine Fassung für PC und iPad)

Drei Signale, jedes 0–100:

| Signal | Woher | Rechnung |
| --- | --- | --- |
| **T** Wochentests | `tests` des Moduls (`module_id`, sonst `subject` = Modulname), abgegeben (`submitted_at`), `max_score > 0`, nur eigene (`user_id` lokal), nach `submitted_at`, dann `id` | Prozent je Test `p_i = 100 · score / max_score` (gedeckelt 0–100), gewichtet **nach Reihenfolge**: der älteste Test wiegt 1, der nächste 2, …, der neueste n. `T = Σ i·p_i / Σ i` |
| **K** Karteikarten | `flashcards` des Moduls (Datei → Kurs → `module_id`, sonst `subject` = Modulname), nicht versteckt (`hidden`), mit letztem Urteil (`last_result` = right/wrong) | `K = 100 · right / (right + wrong)` |
| **A** Aufgaben | `study_tasks` der Lernpakete des Moduls (`study_packages.module_id`) | `A = 100 · erledigt / alle` (`status = 'erledigt'`) |

Gewichte **0,5 · T + 0,3 · K + 0,2 · A**, geteilt durch die Summe der Gewichte der **vorhandenen** Signale (ein Signal
fehlt, wenn es keinen abgegebenen Test, keine bewertete Karte bzw. keine Aufgabe gibt). Ergebnis auf ganze Prozent
gerundet (halbe Prozent aufwärts, `floor(x + 0,5)`, nicht Pythons kaufmännisches `round`), 0–100.

**Kein Signal → `mastery: null`** („noch kein Lernstand“). Die Oberfläche sagt dann, was ihn hebt: „Steigt mit
Wochentests, bewerteten Karteikarten und erledigten Aufgaben.“

**Begründung** (`reason`): die vorhandenen Signale als Text, durch Komma getrennt: „3 Wochentests, 42 Karten, 12 von 20
Aufgaben“ (Einzahl: „1 Wochentest“, „1 Karte“, „1 von 1 Aufgabe“).

Warum so: Wochentests sind der stärkste Beleg, darum das größte Gewicht und die Betonung des neuesten Tests (wer sich
verbessert, sieht das). Karten messen das Behalten, Aufgaben den Fleiß – beide zählen, aber weniger. Nichts wird
geschätzt oder von einer KI erfunden; wer nur Aufgaben abhakt, bekommt nur daraus einen Lernstand, und die
Begründung sagt das.

## Antwortform

`GET /api/modules` (je Modul) und `GET /api/modules/{id}` tragen zusätzlich:

```json
"mastery": {"score": 77, "reason": "2 Wochentests, 42 Karten, 12 von 20 Aufgaben",
            "tests": 2, "cards": 42, "tasks_done": 12, "tasks_total": 20}
```

oder `"mastery": null`. Alle anderen Felder bleiben unverändert (`progress` ist weiter „bearbeitet“: gelesene
Vorlesungen, Übungen und Skripte).

## Umsetzung und Prüfung

| Seite | Rechnung | Anzeige |
| --- | --- | --- |
| Python | `app/mastery.py` (`compute`, `for_module`), eingehängt in `study.module_detail` und `modules_overview` | Web: `app/static/mastery.js` auf den Modulkarten der Übersicht (`views-home.js`), „Meine Module“ und der Modulseite (`views-misc.js`) |
| iPad | `Mastery.swift` (`LocalBackend/Study`), eingehängt in `LocalModules.detail` und `overview` | `LernstandView.swift`: Ring mit „Lernstand 77 %“ und der Begründung als Unterzeile; grau „noch kein Lernstand“ mit dem Hinweis; VoiceOver liest beides |

Gemeinsame Fälle: `packages/shared-contracts/fixtures/mastery/cases.json` (leer, nur Tests steigend und fallend, nur
Karten, nur Aufgaben, gemischt, Test ohne Höchstpunkte, mehr Punkte als Höchstpunkte, halbe Prozent). Geprüft von
`tests/test_mastery.py`, `MasteryTests` (Kern), `LernstandAppTests` (App) und `tests/js/mastery.test.mjs` (Web).
Die aufgezeichneten Antworten der Module-Endpunkte (`fixtures/local-backend/*.json`) tragen das Feld mit.
