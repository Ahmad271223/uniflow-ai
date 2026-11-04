# UniFlow-API für native Clients (iPad, später Windows/Android)

Basis: der bestehende Server (`serve.py`, FastAPI, Port 8765). Alle Pfade unter `/api`.

## Zugang

| Fall | Regel |
| --- | --- |
| Aufruf vom PC selbst (127.0.0.1) | frei |
| Aufruf aus dem WLAN (`serve.py --lan`) | Cookie `lernapp_pin=<PIN>` oder einmalig `?pin=<PIN>` |
| Falsche PIN | `401`; nach 8 Fehlversuchen pro Gerät `429` für 10 Minuten |

Es gibt **noch keine Benutzerkonten**. Der Server ist eine Einzelperson-Installation auf dem eigenen PC.
Konten, Tarife (Free/Plus/Pro) und Store-Käufe sind geplant, aber nicht gebaut (siehe docs/BESTANDSAUFNAHME.md).

## Von der iPad-App genutzt

| Methode | Pfad | Antwort / Zweck |
| --- | --- | --- |
| GET | `/api/settings` | Verbindungstest (401 = PIN falsch) |
| GET | `/api/library` | `{files:[{id,name,title,kind,module_id,subject,doc_type,ai_title,sub_label,downloaded_at,…}], modules:[{id,name,color}], folders, trash}` |
| GET | `/api/files/{id}/content` | Originaldatei (PDF unverändert) |
| GET | `/api/files/{id}/annotations` | `{data, version, updated_at}`; ohne Notizen `version: 0` |
| PUT | `/api/files/{id}/annotations?base_version=N` | `{ok, version}`; **409** `{detail, version, data}`, wenn der Server neuer ist |
| GET | `/api/files/{id}/annotations/versions` | letzte 30 Stände (Wiederherstellung) |
| POST | `/api/files/{id}/annotations/restore/{version}` | Stand wiederherstellen |

Regeln für Notizen (`packages/shared-contracts/annotations.schema.json`):

1. Immer mit `base_version` speichern. Bei 409 den Serverstand holen, eigene geänderte Seiten darauflegen, erneut senden.
2. Unbekannte Felder unverändert zurückschicken.
3. Eine ältere Serverantwort darf den lokalen, ungesendeten Stand nie ersetzen.

## Weitere vorhandene Endpunkte (für spätere native Ansichten)

Übersicht `/api/dashboard`, Module `/api/modules`, `/api/modules/{id}`, Lernkalender `/api/calendar?start=&end=`,
Aufgaben `/api/tasks/open`, `/api/tasks/{id}/status`, Lernpakete `/api/packages/{id}`, Stundenplan `/api/timetable/week?start=`,
`/api/timetable/day?date=`, Tests `/api/tests`, `/api/tests/{id}`, Karteikarten `/api/flashcards` (mit `?stack_id=&due=1`; PATCH auch `question`, `answer`, `subject`, `stack_id`) und ihre Stapel `/api/flashcard-stacks` (GET/POST/PATCH/DELETE `?move_to=`, docs/KARTEIKARTEN-STAPEL-2026-11-04.md), KI-Tutor `/api/ai/tutor`,
Karteikarten aus einem Dokument `/api/ai/flashcards` (nur Vorschlaege; `{file_id, pages?, count?, topic?}` -> `{cards, pages, count}`),
Noten `/api/grades`, Learnweb-Fristen `/api/deadlines`, Dienste `/api/services`, Netzwerk/PIN `/api/network` (nur vom PC sinnvoll).
Kommende Klausuren `/api/exams/upcoming[?module_id=]` (04.11.2026, app/exams.py, Kern `Exams`): `{items, today, filled}`, je
Modul und Tag ein Eintrag aus Stud.IP-Terminen (Art `categories` = Klausur), Klausurtermin am Modul, QIS-Anmeldungen,
Fristen, Ankündigungen und Nachrichten mit `time`, `end`, `room`, `in_days`, `sources`, `source_label`, `user_set`;
füllt leere Klausurtermine der Module (`filled`), nie einen selbst eingetragenen. Fixture `fixtures/exams/exams.json`.
Studienverlauf (04.11.2026, app/study_plan.py, Kern `StudyPlanEngine`/`StudyPlanAPI`, docs/STUDIENVERLAUF-2026-11-04.md):
`GET /api/study-plan` -> `{available, reason (no_catalog|no_catalog_po), message, program, degree, po, code, catalog_term,
start_term, current_term, current_fachsemester, semesters:[{term, fachsemester, current, lp, modules:[{id, title, kind,
lp, semester, turnus, status (bestanden|angemeldet|nicht_bestanden|offen|geplant), attempt, grade, moved_from, reason,
last_attempt}]}], lp_done, lp_total, lp_expected, notes:[{kind, tone, module_id, text}], electives, unmatched,
suggested_po, po_confirmed, qis_program, disclaimer}`; `GET /api/study-plan/module/{id}` (Fakten, `texts`, `own` mit
`attempts`, `prerequisites`, `required_for`, `app_modules`, `courses`, `files`, `source {url, page}`; 404 ohne Katalog
oder Modul); `GET/POST /api/study-plan/settings` `{po, start_term, electives}` (+ Vorschlaege und Auswahllisten; 400 bei
falschem Typ oder unbekanntem Semester). Fixtures `fixtures/study-plan-engine/`.

## Wochentests mit Seitenmarker (ab 3.2)

Marker „Vorlesung bis hier“ und gemeinsame Wochentests: Endpunkte, Datenmodell und Regeln in `docs/WOCHENTESTS.md`.
Native Clients setzen Marker über `POST /api/markers` mit `{file_id, page}` (Originalseite der PDF, 1-basiert) und zeigen
`GET /api/markers?file_id=…` in der Seitenübersicht an. Marker sind keine Annotationen und gehören nicht in `annotations`.
