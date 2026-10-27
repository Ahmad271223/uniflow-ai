# Übergabe an die Mac-Sitzung: PC-Stand 27./28.10.2026 (Windows 0.4.1 bis 0.4.4)

Wunsch des Inhabers, wörtlich sinngemäß: Für jede Person, die sich registriert, muss der Plan **1:1** dem eigenen
Stud.IP-Stundenplan und -Kalender entsprechen. Kurse früherer Semester dürfen **nicht** erscheinen. Die iPad-App soll
alles genauso auslesen und umsetzen wie der PC.

Dieses Dokument führt jede Änderung auf, sagt, was im Swift-Kern und in der App zu tun ist, und nennt die Verträge,
an denen Swift prüft. Alle Verträge sind mit Python 3.14 unter Linux neu erzeugt
(`python tools/gen-*.py`, auf dem Mac direkt aufrufbar) und mit `--check` stabil.

## 1. Kurzfassung: was im Swift-Kern rot wird und warum

| Vertrag | Grund | Swift-Test (vermutlich) |
|---|---|---|
| `fixtures/schema/schema.json`, `legacy.json` | neue Spalten `courses.semester_end`, `courses.semester_ends_at`, `courses.active_custom`, `modules.active_custom`; neue Einstellung `semester_rule_applied = "1"` | `SQLiteStoreTests` |
| `fixtures/local-backend/timetable-logic.json` | jedes Vorkommen hat `source`; Woche enthält Stud.IP-Einzeltermine; `merge_weekly` trennt nach Kurs (neuer Fall „F“) | `LocalTimetableTests` |
| `fixtures/local-backend/study-plan.json` | Vorkommen mit `source` | Study-Tests |
| `fixtures/local-backend/study-modules.json` | `ensure_modules` legt für inaktive Kurse kein Modul mehr an (Modul 9 der Seed-Daten entfällt) | Modul-Tests |
| `fixtures/local-backend/studip-import.json`, `library-files.json`, `demo/demo.json` | Kurszeilen mit den neuen Spalten | Import-, Bibliotheks-, Demo-Tests |
| `fixtures/local-backend/settings-terms.json`, `app-paths.json` | Einstellung `semester_rule_applied` in `GET /api/settings`; Kursspalten in Antworten | Endpunkt-Tests |
| **neu** `fixtures/studip-schedule/woche.json` | Woche 1:1 aus dem Kalender, Semesterregel, Abruf mit `end-semester` | neuer Test nötig, Vorschlag `StudIPWeekTests` |

## 2. Ursache „Mittwoch fehlt“ (echte LUH-Daten, KW 44 und 47/2026)

Am Mittwoch standen in Stud.IP nur Messtechnik I (10:00) und Regelungstechnik II (11:30, 13:15). Beide fehlten im Plan.

- Stud.IP legt dieselbe Veranstaltung **jedes Jahr als neuen Kurs** mit gleichem Titel an. Beispiel Messtechnik I:
  drei Kurs-IDs für WiSe 23/24, 25/26 und 26/27.
- `timetable.merge_weekly` fasste Einzeltermine nach `(Titel, Wochentag, Beginn, Ende)` zusammen, **ohne Kurs**. Drei
  Jahrgänge wurden eine Serie von 2023 bis 2027 mit der Kurs-ID des ältesten Jahrgangs.
- Die Kalenderregel (`_apply_calendar`) suchte künftige Termine dieses alten Kurses, fand keine und traf keine
  Entscheidung. Die Serie zählte dann zu „3 parallele Gruppen, nur deine Gruppe auswählen“ und wurde nie übernommen.
- **Fix:** Schlüssel ist jetzt `(course_id, Titel, Wochentag, Beginn, Ende)`.
  Vertrag: `timetable-logic.json` → `merge_weekly`, letzter Fall mit `course_id` `k-f-24` und `k-f-26` → zwei Serien.
  Dazu `woche.json` → `merge_weekly_multi_year`.
- **Swift:** `LocalTimetableImport.mergeWeekly` (Zeile ~233) genauso gruppieren. Bitte auch in
  `StudIPScheduleImport` prüfen, ob dort irgendwo nur nach Titel gruppiert oder gesucht wird.

## 3. Woche 1:1 aus dem eigenen Stud.IP-Kalender

Neu in `app/timetable.py`: `studip_dated`, `_same_slot`, `_merge_dated`. `occurrences()` ruft sie immer auf, also
gelten sie für Wochenansicht, Tagesansicht, Übersicht, freie Fenster und Planer.

**`studip_dated(conn, start, end)`**
1. Alle `studip_events` aktiver Kurse (`courses.active=1`, `kind != 'sonstiges'`) mit Beginn im Zeitraum.
2. Liegt ein Kalenderabruf vor (`studip_calendar_dates`, Tag des Abrufs = `max(fetched_at)[:10]`): ab dem **Tag nach**
   dem Abruf nur Termine, deren ID im Kalender steht. Davor und ohne Kalender: alle Termine der aktiven Kurse.
3. Jedes Vorkommen: `event_id: null`, `studip_id`, `date`, `start`/`end` (HH:MM), `title` = Kurstitel,
   `kind` = `uebung`, wenn die Kursart `uebung` ist, sonst `guess_kind(title)`, `module_id`, `module_name`,
   `color` = Modulfarbe oder `#4f5bd5`, `room`, `lecturer: null`, `course_id`, `status: teilnahme`,
   `permanent_skip: false`, `exception: null`, `source: "studip-kalender"`.
4. **Gleicher Kurs, Tag, Beginn und Ende** (Stud.IP legt je Raum einen Termin an) → **ein** Vorkommen. Die Räume
   werden in der Reihenfolge des ersten Auftretens mit `" · "` verbunden (U+00B7 mit Leerzeichen), ohne Doppelte.

**`_merge_dated(conn, serien_vorkommen, einzeltermine)`**
- Serien-Vorkommen und Einzeltermin sind **derselbe Termin** (`_same_slot`), wenn Tag und Beginn gleich sind und dazu
  einer gilt: gleiche `course_id`; oder gleiche `module_id` (nicht leer) und gleiches Ende; oder gleicher Titel
  (getrimmt, klein). Treffer: die Serie bleibt (Teilnahme, Ausnahmen, Notizen) und bekommt `studip_id` und, falls
  leer, den Raum. Jeder Einzeltermin wird höchstens einmal verbraucht, in Reihenfolge der Serien.
- Serien mit `source == "studip"` (automatisch übernommen, nicht `studip-manual`, nicht `manual`) eines Kurses, von dem
  es `studip_events` gibt, und ohne `exception == "moved_here"`:
  - ab dem Tag nach dem Kalenderabruf weg, wenn der Kurs **keinen** Termin im Kalender hat (andere Gruppe, altes Jahr);
  - sonst weg, wenn es keinen passenden Einzeltermin gibt und `exception` leer oder `vorlesungsfrei` ist.
    **Gespeicherte Ausnahmen bleiben sichtbar**, z. B. „Ausfall laut Stud.IP“ (`status: ausfall`).
- Alle übrigen Serien (persönlich, von Hand, `studip-manual`, andere Quellen) bleiben unverändert.
- Ergebnis: Serien plus unverbrauchte Einzeltermine, sortiert nach `(date, start)` (stabil).
- `include_skipped=False` filtert erst danach `nicht_teilnahme`.

Jedes Serien-Vorkommen trägt jetzt zusätzlich `source` (= `course_events.source`). Das ist der Grund für die
geänderten Antworten in `timetable-logic.json` und `study-plan.json`.

Abnahme mit echten Daten (Kopie der Datenbank des Inhabers): KW 47 zeigt 21 Einträge wie Stud.IP, darunter
10 Übungen. Mittwoch hat 10:00 Messtechnik I, 11:30 und 13:15 Regelungstechnik II. Die Montags-Übung
Energiewandlung in drei Räumen ist ein Kasten.

Vertrag: `woche.json` → `seed` (SQL nach `init_db` und Kursanlage, in dieser Reihenfolge), dann
`week.studip_dated`, `week.occurrences` (16.–22.11.2026) und `week.busy_2026_11_18` (Einzeltermine zählen als
belegte Zeit). Abgedeckt: andere Gruppe fehlt, veraltete Serie Mo 13:45 fehlt, Serie Mo 15:30 mit Notiz bleibt und
bekommt `studip_id`, von Hand bestätigte Serie ohne Termin bleibt, persönliche Serie bleibt, Ausfall am 19.11.
bleibt mit `status: ausfall`.

## 4. Nur das aktuelle Semester (`app/semesters.py`)

Befund: Stud.IP liefert **alle je belegten** Veranstaltungen. Beim Inhaber waren es 208 Kurse von WiSe 2022/23 bis
WiSe 2026/27, alle aktiv, mit 80 Modulen. Nach der Regel: 11 Kurse aktiv, 10 Module.

**Abruf:** `users/{id}/courses?page[limit]=100&include=start-semester,end-semester`. Je Kurs:
- `semester` = Titel des `start-semester` (wie bisher),
- `semester_end` = Titel des `end-semester`; `"unbegrenzt"`, wenn die Beziehung da ist, aber `data: null`;
  `null`, wenn die Beziehung fehlt (ältere Stud.IP-Fassung),
- `semester_ends_at` = Attribut `end` dieses Semesters (ISO mit Offset) oder `null`.

Attribute einer `semesters`-Ressource laut echter LUH-Antwort: `title`, `token`, `start`, `end`,
`start-of-lectures`, `end-of-lectures`, `visible`, `is-current`.

**Regel `is_current(semester, semester_end, ends_at, today)`**, in dieser Reihenfolge:
1. `semester_end == "unbegrenzt"` → aktuell.
2. `ends_at` vorhanden → aktuell genau dann, wenn `ends_at[:10] >= today` (Textvergleich ISO-Datum).
3. sonst Schlüssel aus `semester_end`, sonst aus `semester`: aktuell genau dann, wenn Schlüssel ≥ heutiges Semester.
4. kein Schlüssel → **keine Entscheidung** (`null`), der Kurs bleibt, wie er ist.

**Schlüssel `key(titel)`**: Regex `\b(WiSe|SoSe|WS|SS|Wintersemester|Sommersemester)\s*'?(\d{2,4})`, ohne Groß-/Klein.
Zweistellige Jahre + 2000. Winter, wenn das Wort mit `wi` oder `ws` beginnt → `(jahr, 2)`, sonst `(jahr, 1)`.
**Heutiges Semester**: April bis September `(jahr, 1)`; Oktober bis Dezember `(jahr, 2)`; Januar bis März
`(jahr − 1, 2)`. Bezeichnung `SoSe 2027` bzw. `WiSe 2026/27`. Heute kommt aus `study.today()` (eingefrorene Uhr).

**Wo die Regel greift**
- `studip_sync.upsert_course`: speichert `semester_end` und `semester_ends_at` (neue Werte nur, wenn nicht `null`)
  und setzt danach `active` nach der Regel, **außer** `active_custom = 1`.
- Abgleich: nach dem Speichern aller Kurse werden Termine, Ankündigungen, Dateilisten und Downloads **nur für aktive
  Kurse** geholt. Alte Kurse kosten keinen Abruf, keinen Download, keine KI-Analyse. Der feste `SEMESTER_FILTER` aus
  der `.env` wird nicht mehr ausgewertet.
- `study.ensure_modules`: legt Module nur für aktive Kurse an. Danach `deactivate_stale_modules`: Module mit
  mindestens einem Kurs, aber keinem aktiven Kurs, und ohne `active_custom` → `active = 0`. Module ohne Kurse
  (selbst angelegt) bleiben.
- `db._init_db` → `semesters.migrate`: einmal je Datenbank alle Kurse (außer `__user__`) nach der Regel schalten,
  dann `deactivate_stale_modules`, dann Einstellung `semester_rule_applied = "1"`. Läuft auch auf einer neuen,
  leeren Datenbank, daher steht die Einstellung jetzt in `schema.json` und `settings-terms.json`.
- `PATCH /api/courses/{id}` mit `active` → zusätzlich `active_custom = 1`.
  `PATCH /api/modules/{id}` mit `active` → zusätzlich `modules.active_custom = 1`.

Vertrag: `woche.json` → `semester_keys`, `current`, `semester_cases`, `fetch_courses` (Antwort und gelesene Kurse),
`courses_in` → `courses_after` und `modules_after`, `user_choice` (eigene Entscheidung bleibt nach erneutem Abgleich).

## 5. Oberfläche (Web/Windows, bitte sinngemäß in SwiftUI)

- **Wochenansicht:** Kurzname statt Initialen. Initialen erst ab **drei** Terminen nebeneinander. Bis zu drei Zeilen
  Titel. Der Raum zeigt alle Räume, jeweils ohne den Teil nach dem Doppelpunkt („Raum F303 · Raum 031“).
- Ein Einzeltermin aus dem Kalender ohne eigene Serie ist antippbar und zeigt nur Titel, Datum und den Hinweis
  „Termin aus deinem Stud.IP-Kalender“. Teilnahme und Notizen gibt es weiter nur für Serien.
- **Einstellungen → Module:** in der Kurstabelle eines Moduls je Kurs ein Häkchen „eingeplant“ und eine Spalte
  „Semester“. Alte Kurse sind ausgegraut. Hinweistext: Kurse aus früheren Semestern erkennt die App am Semester in
  Stud.IP und plant sie nicht ein; ihre Unterlagen bleiben in der Bibliothek.
- **Timer:** die Reiter „Stoppuhr / Countdown / Pomodoro“ ragten aus dem 260 px breiten Fenster, „Pomodoro“ und das
  Schließen-Kreuz waren abgeschnitten. Jetzt 320 px, die Reiter teilen sich die Breite, das Kreuz ist immer sichtbar.
  Bitte auf dem iPad in beiden Ausrichtungen und mit großer Schrift prüfen.

## 6. Weitere PC-Änderungen derselben Tage (zur Einordnung)

| Version | Änderung | Für das iPad |
|---|---|---|
| 0.4.1 | `claude -p` ohne Konsolenfenster unter Windows | nichts zu tun |
| 0.4.1 | „ChatGPT verbinden“ öffnet die Anmeldung als Fenster der Windows-App | nichts zu tun, solange ChatGPT auf dem iPad nicht gebaut ist; später `ASWebAuthenticationSession` |
| 0.4.2 | „Konto entfernen“: `POST /api/university/reset` (`app/reset.py`) löscht Sitzung, Zugangsdaten, Browser-Profile, die ganze Datenbank, Dateien, KI-Arbeitsordner, Protokolle, ChatGPT-Token, Sicherungen und die Cookies des App-Fensters | Abgleichen mit „Daten dieser Hochschule löschen“: nach dem Löschen darf nichts von der vorigen Person bleiben, auch keine Cookies im `WKWebsiteDataStore` der Anmeldefenster |
| 0.4.3 | Semesterregel (Abschnitt 4) | nachziehen |
| 0.4.4 | Kurs im Serienschlüssel, ein Kasten je Termin, Timer (Abschnitte 2, 3, 5) | nachziehen |

## 7. Vorschlag für die Reihenfolge

1. Schema: neue Spalten und `semester_rule_applied` in `Migrations.swift`, `SchemaSQL.swift` ist schon aktuell.
2. `mergeWeekly` mit Kurs im Schlüssel.
3. Semesterregel als eigener Typ (`Semesters`), Abruf mit `end-semester`, `upsertCourse`, `ensureModules`,
   einmalige Umstellung, `active_custom` bei PATCH.
4. `studipDated` und `mergeDated` in `LocalTimetable.occurrences`, `source` an jedem Vorkommen.
5. Neuer Test gegen `woche.json`, dann alle oben genannten Verträge grün.
6. Oberfläche (Abschnitt 5), dann echter Abgleich auf dem iPad: KW 47 muss die 21 Einträge aus Stud.IP zeigen.

Fragen bitte unten in `docs/STAND-MAC-SITZUNG.md` eintragen, die PC-Sitzung liest dort mit.
