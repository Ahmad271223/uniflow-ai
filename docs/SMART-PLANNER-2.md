# Smart Planner 2.0 – Lernziele in Stunden (Auftrag des Inhabers vom 12.11.2026)

Zweig `feature/smart-planner-2`. Technische Arbeitsnotiz je Phase; der Bericht für den Inhaber steht in
`docs/SMART-PLANNER-2-BERICHT.md`.

## Phase A – Bestandsaufnahme

**Wiederverwendbar**
- Lernpakete `study_packages`/`study_tasks` samt Kalender (`StudyCalendar` / `study.calendar`), Wochen-/Tagesraster
  (`PlanGrids.swift`), Verschieben per Ziehen und Dialog (`PATCH /api/packages/{id}`), Abhaken, Geräte-Abgleich G2
  (`study_packages`, `study_tasks`, `modules`, `settings` werden schon zwischen iPad und Mac abgeglichen).
- Freie Fenster `LocalFreeWindows.busyBlocks` (besuchte Termine, Sperrzeiten `blocked_times`, Fahrtzeit).
- Klausurtermine: `modules.exam_date` (selbst eingetragen oder automatisch, Merker `exam_dates_auto`) und
  `Exams.candidates` / `GET /api/exams/upcoming` (Stud.IP-Termine, QIS-Anmeldungen, Noten „angemeldet“, Fristen,
  Ankündigungen, Nachrichten, erkannte Termine aus Dokumenten).
- Einordnung von Dateien in Modul und Lehrwoche (`LocalModules.fileRows`, `LocalModules.week`, `_est`), Merker
  `study_plan_seen_files` für neue Dateien.
- Dateianalysen der KI (Tabelle `analyses`: Art, Dauer, Schwierigkeit, Themen) – werden nur gelesen, nie neu angestoßen.

**Fehlte**
- Ziel-Stunden je Modul, „schreibe ich“, Zweittermin, bestätigter Termin → neue Tabelle `study_goals`.
- Erfasste Lernzeit (Stoppuhr, Eintrag, Korrektur) → neue Tabelle `study_sessions` (eindeutige `uuid`).
- Kennzeichen an Lernpaketen: `source` ('smart' = vom Stundenplaner), `locked`, `manual`.
- Schlaf, Freizeit, Verpflichtungen/Arbeitszeiten, Nutzungsquote → Einstellungen `smart_*`.
- Machbarkeit über alle Klausuren (kumuliert je Klausur), Optionen bei Unterdeckung, Prognose.

**API-Erweiterungen** (gleich am iPad-Kern und im Python-Dienst): `GET /api/goals`, `PUT /api/goals/{module_id}`,
`GET|PUT /api/goals/settings`, `POST /api/goals/plan`, `POST /api/goals/blocks/{package_id}/done`,
`PATCH /api/goals/blocks/{package_id}`, `GET|POST /api/sessions`, `POST /api/sessions/{uuid}/(pause|resume|stop)`,
`PATCH|DELETE /api/sessions/{uuid}`.

**Sync-Wege**: neue Tabellen in `app/db.py` (Schema für beide Seiten generiert) und in den Abgleich-Listen
(`app/sync.py` ENTITIES, `DeviceSyncSchema.entities`) mit natürlichem Schlüssel (`study_goals`: Modul,
`study_sessions`: uuid).

**Risiken**
- Bestehende Automatik (Status ableiten, Pakete ohne Aufgaben „verschoben“, Lernblöcke bei Konflikt neu legen) darf
  Stundenplaner-Blöcke nicht anfassen, sonst würden gesperrte/verschobene Blöcke ungefragt verschoben.
- Zwei Geräte planen offline: gleiche Blöcke doppelt → Planer rechnet deterministisch, doppelte Blöcke werden beim
  nächsten Lauf zusammengeführt; Lernzeit zählt Überlappungen nur einmal.
- Last: der Planer rechnet ohne KI und nur, wenn sich die Eingaben geändert haben (Prüfsumme).
