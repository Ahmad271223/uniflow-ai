# Fristen aus Dateien erkennen und Erinnerungen in Web und Windows (05.11.2026)

Bisher nur auf dem iPad (`DueDetection.swift`, `DueStore.swift`, `DueReminders.swift`, `DueReminderScheduler.swift`).
Jetzt auch im Python-Server (PC und Dienst je Konto) und in der Web-Oberfläche (Browser und Windows-App).

## Erkennen (ohne KI)

- `app/due_detection.py`: Abgaben, Tests, Klausuren, Anmeldungen und sonstige Fristen in Seitentexten, Dateinamen und
  Ankündigungen; Regeln wie in Swift (Schlüsselwort und Datum im selben Satz bzw. in derselben Tabellenzeile, Jahr aus
  dem laufenden Semester plus Prüfungszeit, keine Lösungen/Rückgaben/Einsichten, Überschriften mit Unterpunkten,
  Testat-Spalten, englisch klein „test“ nur mit Prüfungsbezug).
- Gemeinsame Fälle: `packages/shared-contracts/fixtures/due-detection/cases.json` (Erwartungen aus den Swift-Tests
  `DueDetectionTests`/`DueRemindersTests` übernommen; 101 Texte, Semesterfenster, Erinnerungspläne). Python prüft sie in
  `tests/test_due_detection.py`, die Web-Erinnerungen in `tests/js/due-reminders.test.mjs`. Der Swift-Kern kann dieselbe
  Datei lesen (noch nicht verdrahtet).
- `app/due_store.py`: Tabellen `due_hits`, `due_choices`, `due_meta` erst bei Bedarf (nicht im Grundschema). Neu
  gerechnet wird, sobald sich die Eingaben ändern (Seitentexte, Dateien, Kurse, Ankündigungen, Semester, Tag) – beim
  nächsten Lesen von Kalender, Übersicht oder `GET /api/due`. Kennungen der Termine wie auf dem iPad
  (`due-` + 16 Hex aus SHA-256 von Bereich|Tag|Art). Unterschied zum iPad: kein `refreshFile` nach neu gelesenen Seiten
  (deckt der Eingabestand ab); per Texterkennung ersetzter Text auf derselben Seite zählt erst beim nächsten Abgleich oder Tag.

## Endpunkte (`app/due_api.py`, gleiche Form wie `DueEndpoints.swift`)

| Endpunkt | Antwort |
| --- | --- |
| `GET /api/due[?module_id=&hidden=1]` | `{items, hidden, today, refreshed}`; erkannte, Learnweb/Courseware-Fristen, Klausurtermine der Module, mit `days_left`/`in_days` |
| `POST /api/due/refresh` | `{hits, changed}` |
| `POST /api/due/backfill?limit=20` | `{read, remaining}`; nur PDFs auf der Platte, nie über das Netz |
| `PATCH /api/due/{id}` | `{"hidden": true}` („Stimmt nicht“), `{"confirmed": true}`, `{"time": "14:00"}` bzw. `null`; 404 unbekannt |

Wo sie erscheinen: Lernkalender und Stundenplan (`deadlines` je Tag, `holidays.calendar_extras`), Übersicht „Nächste
Termine“ und `GET /api/deadlines` (`study.upcoming_deadlines`), „Nächste Klausuren“ (`exams.candidates`, Art „erkannt“,
ohne Kurz- und Probeklausuren). Nicht doppelt neben einer Learnweb-Frist bzw. dem Klausurtermin des Moduls am selben Tag.
Das Detail eines Chips (`core.js` `chipDetail`) zeigt „Im Dokument“, „Stimmt“ und „Stimmt nicht“.

## Erinnerungen (`app/static/due-reminders.js`, Logik `due-reminders-logic.js`)

- Plan wie auf dem iPad: 3 Tage vorher, 1 Tag vorher und am Morgen um 8:00 (Berlin), mit Uhrzeit 2 Stunden vorher;
  höchstens 60, nur künftige.
- Eingeschaltet über den Knopf „Erinnern“ in der Karte „Nächste Termine“ (Stand je Browser). Die Erlaubnis wird erst
  beim Klick erfragt.
- Windows-App: Windows-Mitteilung über `tauri-plugin-notification` (`apps/windows/src-tauri/Cargo.toml`, `main.rs`,
  Fähigkeit `capabilities/notifications.json` nur für `http://127.0.0.1:*/*` und nur `notification:default`).
  Browser: Notification-API. Ohne Erlaubnis: Hinweis unten rechts in der App.
- Solange StudiNow offen ist: Abruf beim Start und alle 30 Minuten, Zeitgeber für die nächsten 26 Stunden. Einmal am
  Tag ein Hinweis „Bald fällig“ mit den Terminen von heute und morgen. Geschlossene App erinnert nicht (kein
  Hintergrunddienst am PC).

## Offen

- Windows-Bau mit dem neuen Plugin auf dem Runner prüfen (hier kein `cargo`).
- `tools/gen-local-backend-fixture.py` führt `/api/due` noch als „nur auf dem Gerät“ (`python: False`); die Routen gibt
  es jetzt auch in Python. Umstellen ändert die Fixture für die Swift-Abdeckungstests und braucht einen Swift-Lauf.
- Hinweise aus Ankündigungen am selben Tag wie ein erkannter Termin werden im Web noch nicht ausgeblendet
  (`DueStore.withoutDuplicateNotices` auf dem iPad).
