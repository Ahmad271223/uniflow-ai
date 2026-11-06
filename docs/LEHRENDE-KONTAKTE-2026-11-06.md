# Lehrende und Kontakte (LUH, Stud.IP), 06.11.2026

Auftrag des Inhabers (06.11.2026, wörtlich): „baue noch eine funktion e-mails der lehrer zu finden die kann man über
studip sehen bei luh; für lsf und hsh machen wir das in einer späteren version“.

StudiNow zeigt jetzt zu jedem Modul die **Lehrenden** (Dozent/innen und Tutor/innen) mit Name, Rolle, E-Mail-Adresse,
Sprechstunde, Raum und Einrichtung, soweit Stud.IP sie der eigenen Sitzung zeigt, und eine durchsuchbare Liste aller
Lehrenden der eigenen Kurse. Nur an der **Leibniz Universität Hannover** (Stud.IP). **HsH und Uni Hildesheim: später**
(LSF bzw. Moodle/HISinOne). Dort ist der Bereich unsichtbar, ohne Platzhalter.

## 1. Quelle: Stud.IP-JSON:API (nur lesend)

Keine Anfrage an die LUH während der Entwicklung. Grundlage: der bestehende Stud.IP-Client (`StudIPClient`,
`app/studip_sync.py` `_api_get`), die öffentliche Stud.IP-Entwicklerdoku
([JSON:API Veranstaltungen](https://docs.gitlab.studip.de/entwicklung/jsonapi/courses/),
[Nutzer](https://docs.gitlab.studip.de/entwicklung/jsonapi/users/),
[Einrichtungen](https://docs.gitlab.studip.de/entwicklung/jsonapi/institutes/)). Der Quelltext auf gitlab.studip.de war
für Werkzeuge gesperrt (Bot-Schutz); er wurde nicht umgangen.

**Live bestätigt am 06.11.2026** (Anmeldung des Inhabers, nur GET, anonymisiert; Notiz
`~/Studora-Builds/lehrende/STRUKTUR-ECHT-2026-11-06.md`, nicht im Repo): JSON:API mit den Sitzungs-Cookies, alle 200.
Die Fixtures bleiben **ausgedacht** (erfundene Namen, nur example.org), haben aber den bestätigten Aufbau.

| Zweck | Anfrage | Felder | Stand |
|---|---|---|---|
| Lehrende eines Kurses | `GET courses/{id}/memberships?filter[permission]=dozent&page[limit]=100&include=user` | Typ `course-memberships`; `permission`, `position`, `label` („Funktion“); Beziehung `user` | **live bestätigt 06.11.2026**: Filter wirkt (`meta.page.total` = Zahl der Lehrenden); `included` Typ `users` **mit `email`** (Adressen der Institute an der LUH), `formatted-name`, `name-prefix`, `name-suffix`; Mitgliedschaft mit `permission`, `position`, `group`, `mkdate`, `label`, Beziehungen `course`, `user`. Ohne Filter kämen auch Studierende (`autor`) – darum immer mit Filter und Rollenprüfung |
| Tutor/innen | dieselbe mit `filter[permission]=tutor` | wie oben | **live bestätigt 06.11.2026** |
| ohne `include` (400) | dieselbe ohne `&include=user`, dann `GET users/{id}` je Person ohne Namen (höchstens 20 je Lauf) | `formatted-name`, sonst `name-prefix`, `given-name`, `family-name`, `name-suffix`; `username`; `email` | Rückfall, an der LUH nicht nötig (`include=user` geht, live 06.11.2026); `users/{id}` selbst nicht einzeln getestet: **braucht einen echten Test**, falls er je greift |
| Sprechzeiten, Raum | `GET users/{id}/institute-memberships?include=institute` (400: ohne include), **nur für Dozent/innen** | Typ `institute-memberships`; `office-hours` (freier Text, oft null), `location` (Raum, oft null), `is-default`, `priority`; `phone`, `fax` (liest StudiNow nicht); Beziehung `institute` → `name` | **live bestätigt 06.11.2026** |
| Nachricht | `POST messages` (wie „Antworten“, docs/NACHRICHTEN-ANTWORTEN-2026-11-05.md) mit genau einem Empfänger | – | Senden selbst am 05.11.2026 echt getestet (Antworten); an eine Kennung aus `memberships`: **braucht einen echten Test** (nicht ausgelöst) |
| Ausweg im Browser | `dispatch.php/messages/write?rec_uname={username}` | – | Parameter aus der Stud.IP-Oberfläche bekannt, nicht dokumentiert. **Braucht einen echten Test** |

Regeln beim Lesen (`app/studip_lecturers.py` = `StudIPLecturers.swift`):

- Nur Einträge vom Typ `course-memberships` mit `permission` **dozent** oder **tutor**. Alles andere (Studierende, ein
  ignorierter Filter) fällt weg und wird **nie gespeichert**. Doppelte Personen zählen einmal.
- E-Mail nur, wenn sie wie **eine** Adresse aussieht (`name@domain.tld`, keine Leerzeichen, kein `<>,;`). Sonst leer:
  die Oberfläche zeigt **„Nachricht über Stud.IP“** und den Knopf „Nachricht in Stud.IP“.
- Sprechzeiten: HTML zu Text (`html_to_text`), höchstens 400 Zeichen; Standard-Einrichtung (`is-default`) zuerst, dann
  `priority`; genommen wird die erste mit Sprechzeiten oder Raum.
- 403 bei einem Kurs (Teilnehmende versteckt): Kurs gilt als gelesen, ohne Lehrende („In Stud.IP sind für diese Kurse
  keine Lehrenden sichtbar.“). 404 bei **allen** Kursen eines Laufs: Route fehlt, 30 Tage Ruhe
  (`settings.studip_missing_endpoints["course-memberships"]`, wie die Stud.IP-Ergänzungen). 404 bei der ersten
  Sprechzeiten-Abfrage: 30 Tage Ruhe für `institute-memberships`.

## 2. Wann: nach dem aktuellen Semester

Reihenfolge laut docs/SYNC-REIHENFOLGE-2026-11-05.md: **erst nach Stufe (a)** (Kursliste, Stundenplan, Dateien,
Ankündigungen des aktuellen Semesters; `mark_current_ready` / `SyncOrder.markCurrentReady`), nie davor.

| | iPad | PC/Windows |
|---|---|---|
| Aufruf | `StudIPSync.perform` → `StudIPExtrasSync.lecturers` nach den Stud.IP-Ergänzungen, nur im vollen Lauf (nicht im kurzen Hintergrundlauf `.lists`) | `run_studip_sync` nach `mark_current_ready`, nur `lecturers_allowed()` (lokal, LUH) |
| Kurse | gewählte aktive Kurse des aktuellen (und nächsten) Semesters | `current + upcoming` |
| Häufigkeit | je Kurs höchstens alle **7 Tage** (`studip_lecturer_courses.fetched_at`), höchstens 30 Kurse je Lauf | gleich |
| Anfragen | je Kurs 2 (Dozent/innen, Tutor/innen), dazu höchstens 20 `users/{id}` und 40 Sprechzeiten (nur Dozent/innen) je Lauf | gleich |

Gespeichert mit den Kursdaten in der Datenbank des Containers: Tabellen `studip_lecturers` (Kurs, Person, Rolle,
Position, Funktion, Name, Benutzername, E-Mail, Sprechzeiten, Raum, Einrichtung) und `studip_lecturer_courses`.
„Daten dieser Hochschule löschen“ entfernt sie mit dem Container.

## 3. Anzeige

`GET /api/lecturers[?course_id=|module_id=][&q=]` (Python = lokales Backend):

```json
{"available": true, "university": "luh", "count": 2, "total": 5, "loaded": true, "updated_at": "…", "hint": null,
 "no_email": "Nachricht über Stud.IP",
 "people": [{"id": "u-prof", "name": "Prof. Dr. Erika Beispiel", "email": "erika.beispiel@example.org", "has_email": true,
             "no_email": null, "roles": ["dozent"], "role_label": "Dozent/in", "label": "Modulverantwortliche",
             "office_hours": "Di 10–11 Uhr\nund nach Vereinbarung", "location": "Raum F 303 (1101)",
             "institute": "Institut für Testmathematik", "username": "beispiel",
             "courses": [{"course_id": "k-ana", "title": "Analysis I – Vorlesung", "module_id": 1, "module_name": "Analysis I",
                          "role": "dozent", "role_label": "Dozent/in"}],
             "message_url": "https://studip.uni-hannover.de/dispatch.php/messages/write?rec_uname=beispiel",
             "mailto": "mailto:erika.beispiel@example.org"}]}
```

Kurs/Modul: Dozent/innen vor Tutor/innen, dann Stud.IP-Reihenfolge; ohne Kurs und Modul alle **aktiven** Kurse nach
Name. Suche `q`: Name, E-Mail, Kurs oder Modul (ohne Groß/klein). Leer: `hint` („Die Lehrenden kommen mit dem nächsten
Stud.IP-Abgleich …“, „In Stud.IP sind für diese Kurse keine Lehrenden sichtbar.“, „Keine Lehrenden gefunden.“).
HsH, Hildesheim und der gehostete Dienst: `available: false`, keine Personen.

| Ort | iPad | Web/Windows |
|---|---|---|
| Modulseite, Übersicht | `ModuleLecturersCard` (Views/Lecturers/LecturersViews.swift) unter „Aus Stud.IP“, nur mit Einträgen | `mountModuleLecturers` (lecturers.js) in `#lecHost` |
| Seite „Lehrende“ | Route `.lecturers` / `#/lehrende`, Suche „Suchen (Name oder Modul)“, „3 Personen“ bzw. „1 von 3 Personen“ | `viewLecturers`, Route `#/lehrende` |
| Einstieg | Knopf „Lehrende“ auf der Uni-Mail-Seite, „Alle Lehrenden“ im Bereich der Modulseite | Link „Lehrende“ auf der Uni-Mail-Seite, „Alle Lehrenden“ |
| E-Mail antippen | Uni-Mail verbunden: neue E-Mail (`UniMailComposeSheet`, `UniMailComposeRequest.to`, Betreff „Frage zu <Modul>“); sonst `mailto:` | Uni-Mail verbunden: `uni-mail.js` `composeTo`; sonst `mailto:` |
| „Nachricht in Stud.IP“ | `MessageReplySheet` mit festem Empfänger (`MessageReplyOriginal.direct`, Entwurf „lect-<Kennung>“, Betreff Pflicht, kein Zitat), Ausweg „In Stud.IP schreiben“ (`rec_uname`) | Fenster mit `POST /api/lecturers/{id}/message` (nur Personen aus `studip_lecturers`, genau ein Versuch), Ausweg „In Stud.IP schreiben“ |
| Raum, Sprechstunde | Raum als `UFRoomLink` (Raumfinder); Zeilen der Sprechstunde mit Raum/Gebäude (`Rooms.parse … linkable`) ebenso, Zeiten bleiben Text | `.room-link` (Raum; Zeilen mit Raumkennung, `namesRoom`) |

Bedienungshilfe je Zeile: „Name, Rolle, E-Mail … bzw. Nachricht über Stud.IP, Sprechstunde …, Raum …“.

## 4. Datenschutz

Namen, Adressen und Sprechzeiten bleiben **auf dem Gerät bzw. PC** (am PC nur im Einzelplatz-Betrieb). Der gehostete
Dienst liest und speichert sie nie (`lecturers_allowed`, `allowed=not is_hosted()`). Keine Daten anderer
Studierender. An Uni-Mail bzw. das Mailprogramm geht eine Adresse erst beim Antippen. Satz in
docs/release/DATENSCHUTZ.md Abschnitt 4 (Seite neu erzeugt mit `python tools/gen-site.py`).

Ausnahme zur Regel „keine Personennamen speichern“ (02.11.2026, Nachrichten): hier ausdrücklich gewünscht und nur für
Lehrende und Tutor/innen der eigenen Kurse, deren Namen Stud.IP im Kurs ohnehin zeigt.

## 5. Umsetzung

| Teil | Dateien |
|---|---|
| Python | `app/studip_lecturers.py` (Lesen, Speicher, Abruf, Übersicht), `app/studip_lecturers_api.py` (Routen), Aufruf in `app/studip_sync.py`, Router in `app/server.py` |
| Swift-Kern | `UniFlowCore/StudIPLecturers.swift`, `LocalBackend/Endpoints/StudIPLecturersEndpoints.swift` |
| iPad | `Views/Lecturers/LecturersViews.swift`, `Services/StudIPExtrasSync.swift` (`lecturers`), `Services/StudIPSync.swift`, `Services/StudIPMessageSender.swift` (`direct`), `Views/Messages/MessageReplySheet.swift`, `Views/UniMail/UniMailViews.swift` (`to`, Knopf), `Views/Modules/ModulesPage.swift`, Route in `Design/AppShell.swift`, `Views/MainView.swift` |
| Web/Windows | `app/static/lecturers-logic.js`, `lecturers.js`, `uni-mail.js` (`composeTo`, Link), `views-misc.js`, `app.js`, `style.css` |
| Fixtures | `packages/shared-contracts/fixtures/studip-lecturers/lecturers.json` aus `tools/gen-studip-lecturers-fixture.py [--check]` (erfundene Namen, nur example.org); `fixtures/local-backend/app-paths.json`; Debug-Nachbildung `apps/apple/DebugStub/erststart/studip-members-*.json`, `studip-institute-u-stub-doz.json` |
| Tests | `tests/test_studip_lecturers.py`, `StudIPLecturersTests.swift` (Kern), `tests/js/lecturers.test.mjs`, `LecturersAppTests.swift` (App mit `DebugStubTransport`) |

## 6. Einmal echt prüfen (Inhaber, mit eigenem Konto)

Aufbau der Antworten ist live bestätigt (Abschnitt 1). Offen sind nur der Lauf in der App und das Senden:

1. iPad: Stud.IP-Abgleich laufen lassen, danach ein Modul öffnen: steht „Lehrende“ mit Namen? Stimmen Rolle und
   E-Mail mit der Teilnehmerliste in Stud.IP überein? Fehlt eine Adresse, die Stud.IP im Profil zeigt?
2. Steht keine Person da: im Protokoll („Lehrende: …“) bzw. in `settings.studip_missing_endpoints` nachsehen.
3. Sprechstunde und Raum: mit dem Profil einer Lehrperson in Stud.IP vergleichen (Einrichtung, Sprechzeiten).
4. „Nachricht in Stud.IP“ an sich selbst ist nicht möglich; am besten an eine Tutorin/einen Tutor mit Absprache senden und
   in Stud.IP unter „Gesendet“ prüfen. „In Stud.IP schreiben“: ist der Empfänger voreingetragen (`rec_uname`)?
5. Uni-Mail verbunden: E-Mail-Adresse antippen → neue E-Mail mit Empfänger und Betreff „Frage zu <Modul>“.

## 7. Später

- **HsH** (Moodle-Teilnehmerliste bzw. HISinOne) und **Uni Hildesheim** (Learnweb/LSF): in einer späteren Version.
- Telefonnummern (`phone` in `institute-memberships`) liest StudiNow bewusst nicht.
