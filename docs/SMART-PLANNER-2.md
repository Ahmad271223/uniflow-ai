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

## Phase B – Datenmodell und Migrationen

- Neue Tabellen in `app/db.py` (Schema für beide Seiten generiert, `tools/gen-swift-schema.py`): `study_goals`
  (ein Ziel je Modul: Ziel-Minuten, schon gelernt, Pflichtveranstaltungen zählen, schreibe ich, Erst-/Zweittermin,
  bestätigter Tag, Priorität) und `study_sessions` (uuid, Modul, Block, Art timer/manual/block, Zustand, Zeitabschnitte
  als Unix-Sekunden, Minuten, Tag, gelöscht).
- Neue Spalten an `study_packages`: `source` ('smart'), `locked`, `manual` (Python `add_col`, Swift `Migrations.steps`,
  gleiche Reihenfolge). Nur Hinzufügen – alte Datenbanken bleiben lesbar, alte App-Stände ignorieren die Spalten.
- Abgleich zwischen Geräten: beide Tabellen in `app/sync.py` ENTITIES und `DeviceSyncSchema.entities`, natürlicher
  Schlüssel Modul bzw. uuid. Einstellungen `smart_planner`, `smart_plan_state`, `smart_plan_proposal` gleichen sich mit.
- Zusammenführen doppelter Module nimmt Lernziel und Lernzeit mit (`study.merge_duplicate_modules`).
- Nebenbei: `tools/gen-schema-fixture.py` schreibt `user_version` 0 (Fingerabdruck nur am PC/Dienst), sonst passte die
  Schema-Fixture seit dem 08.11. nicht mehr zum Gerät.

## Phase C – Rechenkern (`app/smart_planner.py` = `SmartPlanner.swift`)

- Harte Bedingungen: freie Fenster (Schlaf, Freizeit, Termine samt Fahrtzeit, Sperrzeiten, Verpflichtungen, feste
  Blöcke abgezogen), heute nicht vor jetzt, nie am/nach dem Klausurtag, Tagesbudget = Nutzungsquote × freie Zeit
  (feste Blöcke des Tages zählen darauf), Tages-/Wochenobergrenze.
- Machbarkeit kumuliert je Klausur. Unterdeckung: keine Blöcke, Meldung „670 h nötig, 350 h verfügbar, fehlen 320 h“,
  Optionen (Quote, Freizeit, Ziele, Zweittermin/späterer Termin, Prioritäten, Teilplan). Bei 100 % kein Quotenvorschlag.
- Verteilung Tag für Tag: Wunsch = (Rest + eigene feste Blöcke) × Tagesbudget / Budget bis zur Klausur, aufgerundet;
  Zwischenfristen werden je Tag abgesichert (frühere Klausuren zuerst); bisherige Lagen werden bevorzugt (geringste
  Änderung); Pausen nur aus Spielraum.
- Lernzeit: dieselbe uuid einmal, Überlappungen einmal (auch über Geräte und Zeitzonen, Unix-Sekunden), Haken mit
  Minuten ersetzt die Stoppuhr des Blocks, nichts in der Zukunft.
- Material ins Budget: Datei in bis zu 4 Teilen in die nächsten Blöcke ab ihrer Lehrwoche, Rest = Konflikt.
- Abgleich Python ↔ Swift: `tools/gen-smart-planner-fixture.py` (48 Planungsfälle, Tage, Lernzeit, Abgleich,
  Material, Prognose) → `SmartPlannerParityTests`.

## Phase D – Dienst und iPad-Kern

- Python `app/smart_goals.py` (Router), Swift `SmartGoals.swift` + `SmartGoalsEndpoints.swift`; gleiche Pfade.
- Neuplanung nur bei geänderter Prüfsumme der Eingaben; bis 8 geänderte Blöcke automatisch, sonst Vorschlag;
  Unterdeckung nie still. Jede Anfrage eine Transaktion mit sofortiger Schreibsperre (doppelt gestartet = einmal).
- Schutz der Blöcke: `refresh_statuses`, `_recalc_package`, `_replaceable`, `reslot_day`, `repairSlots`,
  `auto_plan_week`, `insertNewFiles` lassen Stundenplaner-Blöcke in Ruhe; Verschieben von Hand setzt `manual=1`.
- Automatisches Umplanen am iPad ab Plus (`SmartGoalsEndpoints.autoAllowed` = `UFFeature.autoPlan`); Ziele,
  Lernzeit, Übersicht in jedem Tarif.

## Phase E – iPad-Oberfläche

- Lernkalender bekommt die Ansicht „Lernziele“ (`#/plan?view=ziele`, `Views/Goals/GoalsPage.swift`): Kennzahlen,
  Vorschlag/Unterdeckung mit Optionen, laufende Stoppuhr, Module mit Fortschritt/Prognose/Klausur (unbestätigt →
  Bestätigen), Woche geplant gegen gelernt, Konflikte, Module ohne Ziel.
- Dialoge (`GoalsDialogs.swift`): Lernziel (mit gefundenen Klausurterminen zum Übernehmen), Zeitrahmen (Schlaf,
  Freizeit, Quote, Blocklängen, Arbeit/Verpflichtungen), Zeit eintragen, Block abhaken mit Minuten.
- Lernpaket-Drawer zeigt bei Stundenplaner-Blöcken Abhaken mit Zeit, Stoppuhr, Sperren; Verschieben prüft vorher
  Konflikte. Status „Verpasst“ im Design.
- Alle neuen Ansichten als kleine eigene Typen, `PlanView`, `GoalsPage`, `GoalsBody`, Dialoge im `ViewTypeDepthAppTests`.

## Phase F – Tests und Last

- Python: `tests/test_smart_planner.py` (Rechenkern, 300 Zufallsfälle), `tests/test_smart_goals.py` (Endpunkte),
  `tests/test_rechte_alle_routen.py` (fremde Konten, läuft automatisch über die neuen Routen).
- Swift: `SmartPlannerParityTests`, `SmartGoalsTests` (14 Szenarien über die Endpunkte des Kerns).
- Last: `tools/lasttest-smart-planner.py`, Ergebnisse im Bericht.
