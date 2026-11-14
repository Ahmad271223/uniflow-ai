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

## Teil 2: Echte Aufgaben und Lernschritte (14.11.2026, nach den Beispielen „Signale und Systeme“)

Beispiele des Inhabers (nicht im Repository, lokal unter ~/Studora-Builds/beispiel-unterlagen): Skript mit
Inhaltsverzeichnis (123 Seiten, 10 Kapitel, rund 40 Abschnitte, Text lesbar) und Arbeitsblätter (71 eingescannte
Seiten, 34 Merk- und Formelblätter AB 20–177, ohne Text und ohne Inhaltsverzeichnis, keine Rechenaufgaben).
Entscheidung des Inhabers: Lernschritte ohne KI, in jedem Tarif.

- **Gliederung** (`app/outline.py`, `StudyOutline.swift`): Lesezeichen der PDF → Abschnitte mit Nummer, Titel, Kapitel
  und Seiten (Titelseite, Inhaltsverzeichnis, Literatur entfallen; Unterabschnitte der dritten Ebene gehören zu ihrem
  Abschnitt). Gelesen beim Planen und nach dem Abgleich, gespeichert in `file_outline` (je Gerät, nicht abgeglichen).
  pypdf am PC und PDFKit am iPad lesen dasselbe – geprüft an einer Muster-PDF (`outline-sample.pdf`) und am echten
  SigSys-Skript (39 Abschnitte, gleiche Aufgaben).
- **Echte Aufgaben**: statt „Skript.pdf (Teil 1/4)“ z. B. „1 Fourier-Reihe · S. 7–16“ (ganzes Kapitel) oder „2.1
  Grundlegende Beziehungen bis 2.4 · S. 17–29“. Nie über eine Kapitelgrenze, nie länger als die Lernzeit je Fach;
  ein zu langer Abschnitt nach Seiten („…, Teil 1/2 · S. 12–16“). Dauer nach Seiten (Skript/Vorlesung mindestens
  4 Minuten je Seite). Was in der Lehrwoche nicht in den Plan passt, kommt in der nächsten Woche (ab der ersten noch
  nicht geplanten Seite). Skripte werden jetzt eingeplant, wenn sie ein Inhaltsverzeichnis haben (vorher nie); ohne
  Inhaltsverzeichnis bleibt alles wie bisher. Gescannte Unterlagen ohne Inhaltsverzeichnis: Seitenbereiche.
- **Lernschritte** je Aufgabe (Vorlesung/Skript: Überfliegen – Lesen und Formeln herausschreiben – Beispiel nachrechnen
  – in zwei Sätzen erklären; Übung: gegeben/gesucht – Formel suchen – rechnen – Ergebnis prüfen; Lösung: erst selbst,
  vergleichen, schwierigste Stelle noch einmal). Abhaken je Schritt (`POST /api/tasks/{id}/steps`), alle abgehakt =
  Aufgabe erledigt, einer wieder offen = wieder geplant. „Öffnen“ springt auf die erste Seite der Aufgabe.
- Datenmodell: `study_tasks.page_from`, `page_to`, `steps` (JSON), `steps_done` (JSON), neue Tabelle `file_outline`.
- Tests: `tests/test_outline.py`, `outline.json` (`StudyOutlineTests`), study-plan.json Szenario `gliederung`
  (`LocalStudyPlanTests.testOutlineTasksAndStepsMatchPythonServer`), Browser `test_web_plan_choice.py`.
- Offen: Arbeitsblätter als einzelne Blätter („AB 41 Fourier-Reihe“) bräuchten Texterkennung der eingescannten Seiten;
  bis dahin Seitenbereiche. Lernschritte sind je Aufgabenart gleich, nicht je Inhalt.
