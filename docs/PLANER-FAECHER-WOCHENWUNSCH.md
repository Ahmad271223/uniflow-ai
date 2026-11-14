# Lernplaner: Fächer, Wochenwunsch, „Thema gemacht“ (Auftrag des Inhabers 14.11.2026, Teil 1)

Zweig `planer/faecher-wochenwunsch`. Nicht Teil von Build 41. Noch nicht enthalten: echte Aufgaben statt Dateinamen
und Schritt-für-Schritt-Erklärungen (dafür schickt der Inhaber erst Beispiel-Unterlagen).

## Plan

**Datenmodell** (nur Einstellungen, keine neue Tabelle; alles gleicht sich wie die übrigen Lerneinstellungen ab):
- `plan_modules_off` (gibt es schon): Namen der Fächer, die der Lernkalender nicht plant.
- neu `plan_week_wish`: `{"week": "<Montag>", "modules": ["Fach", …]}` – gilt nur in dieser Woche. Wie bei
  `plan_modules_off` stehen Namen statt IDs darin, weil die IDs je Gerät verschieden sind.

**Fächer in den Planer-Einstellungen** („Meinen Lernplan konfigurieren“, dort, wo die Lerntage stehen):
- Abschnitt „Fächer“: alle aktuellen Module (aktives Semester) mit Haken, dazu ein Feld „Fach hinzufügen“.
- `GET/POST /api/calendar/modules` gibt es jetzt auch am PC (bisher nur auf dem iPad); `{"add": "Name"}` legt ein
  eigenes Fach an (oder hakt ein vorhandenes gleichen Namens an).
- Abgewählt heißt weiter: nie verplant, auf keinem Weg (Test aus Build 37 bleibt, neue Wege kommen dazu).

**Wochenwunsch** (`GET/PUT /api/calendar/week-wish`):
- Speichern plant den Rest dieser Woche neu. Unberührte automatische Pakete werden ersetzt, eigene, begonnene und
  gesperrte bleiben. Bei Lernzielen in Stunden wird der Stundenplan neu verteilt.
- Alter Lernplan: in dieser Woche zuerst Fächer mit Klausur in den nächsten 14 Tagen (nichts geht verloren), dann die
  Wunschfächer; andere Fächer nur, wenn die Wunschfächer an dem Tag nicht reichen.
- Lernziele in Stunden: an den Tagen dieser Woche bekommen die Wunschfächer die Zeit der anderen. Danach sichert die
  vorhandene Prüfung der Zwischenfristen jede Klausur ab: Was eine frühere Klausur braucht, bleibt.

**„Thema gemacht“** (`POST /api/calendar/topic-done` mit `task_ids`, optional `in_package`):
- Die Aufgaben sind erledigt. Dieselbe Datei in anderen Paketen wird mit erledigt, damit nichts doppelt bleibt; es
  entstehen keine zusätzlichen „Wiederholung“-Einträge.
- Lag das Thema an einem späteren Tag, wird dieser Termin frei: Das Paket verschwindet, wenn es sonst leer ist; die
  erledigten Aufgaben stehen dann im Paket von heute.
- Mit `in_package` (man hat im Termin eines anderen Fachs gelernt): Die offenen Aufgaben dieses Termins rücken in den
  frei gewordenen Termin. Gibt es keinen, kommen sie auf die nächsten Lerntage mit freier Zeit (wie „Neu einplanen“).
- Stundenplaner-Blöcke bleiben stehen (sie sind Lernzeit); ihre Unterlagen füllt der Planer beim nächsten Öffnen nach.

**Oberfläche** (iPad und iPhone): Fächer-Abschnitt im Konfigurations-Dialog; Knopf „Diese Woche“ im Lernkalender;
im Lernpaket „Schon gemacht“ je Aufgabe und „Anderes Fach gemacht“.

## Stand (14.11.2026)

- Kern Python `app/study_choice.py` (+ Wunsch in `study.generate_packages` und `smart_planner._allocate`, Eingabe in
  `smart_goals.build`), Swift `StudyChoice.swift`, `StudyPlanModules.addSubject`, `StudyPlan.generatePackages`,
  `SmartPlanner.allocate`, `SmartGoals.build`. Verschobene Aufgaben verlieren ihre alte Uhrzeit (gehörte zum alten
  Termin).
- Abgleich: `study-plan.json` Szenario `faecher_wunsch` (`LocalStudyPlanTests.testSubjectsWishAndTopicDoneMatchPythonServer`),
  `smart-planner.json` mit 14 Wunsch-Fällen (`SmartPlannerParityTests`), Regeln in `tests/test_study_choice.py`.
- Oberfläche (iPad und iPhone, gleiche Ansichten): `Views/Plan/PlanChoiceViews.swift` – Abschnitt „Fächer“ in
  „Lernkombination“, Knopf „Diese Woche“ (iPhone: im Menü „Mehr“), im Aufgaben-Menü „Thema schon gemacht“, im Lernpaket
  „Hier ein anderes Fach gemacht“.
- Web/PC (Nachtrag 14.11.): `app/static/plan-choice.js` – dieselben vier Stellen im Browser
  (`tests/test_web_plan_choice.py`, feste Uhr).
- App-Pfad-Abgleich (`app-paths.json`) wieder vollständig: Beispiele für die Modul-Pfade (Abschnitte, Einordnen,
  Vorschläge, Haken, Layout). Dabei behoben: „Abschnitt anlegen/umbenennen“ in `ModuleLayoutViews.swift` schickte GET
  statt POST und konnte so nie gespeichert werden; die übrigen Aufrufe nennen ihre Methode jetzt ausdrücklich.
- Offen: Prüfung am Gerät; echte Aufgaben statt Dateinamen und Schritt-für-Schritt-Erklärungen (warten auf Beispiel-
  Unterlagen des Inhabers). Bekannt und nicht von hier: `gen-local-backend-fixture.py` schreibt vier ältere
  Abgleichsdateien (Bibliothek, Einstellungen, Stud.IP-Import, Module) anders als der iPad-Kern sie erwartet; sie
  bleiben auf dem develop-Stand.
