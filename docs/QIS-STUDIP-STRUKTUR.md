# Aufbau von QIS und Stud.IP (für den nativen Abruf auf dem iPad)

Stand 25.10.2026. Gelesen im Browser, nachdem sich der Inhaber **selbst** angemeldet hat; keine Claude-Sitzung tippt
Zugangsdaten. Festgehalten ist nur der Aufbau (Navigation, Abfragen, Feldnamen, Formate) – keine persönlichen Daten,
keine Noten, keine Sitzungsschlüssel. Grundlage für den Ersatz von `qis.py` und für den fehlenden Stundenplan-Teil von
`StudIPSync` (siehe WEB-IPAD-PARITAET.md, „Ersatz der Python-Serverlogik“).

## QIS (qis.verwaltung.uni-hannover.de)

Alle Seiten laufen über `…/qisserver/servlet/de.his.servlet.RequestDispatcherServlet?state=…`. Viele Links tragen den
Sitzungsparameter `asi=…`; er muss aus der aktuellen Seite genommen und darf nie gespeichert werden.

| Seite | Aufruf (ohne asi) | Inhalt |
|---|---|---|
| Startseite | `state=user&type=0` | „Meine Funktionen“: Meine Benutzerdaten, Mein Studium, Meine Bescheinigungen, Logout |
| Mein Studium | `state=change&type=1&moduleParameter=studyPOSMenu&next=menu.vm` | Prüfungsanmeldung/-abmeldung, Info über angemeldete Prüfungen, **Notenspiegel / Studienverlauf**, Mein Stundenplan |
| Notenspiegel (Baum) | `state=notenspiegelStudent&next=tree.vm&nextdir=qispos/notenspiegel/student` | Baum „Abschluss <Nr> <Name>“ (`nodeID=auswahlBaum\|abschluss:abschl=<Nr>`), aufklappen mit `expand=0`; darunter je Studiengang ein Link „Leistungen für <Studiengang> (PO-Version <Jahr>) anzeigen“ |
| Leistungen | `state=notenspiegelStudent&next=list.vm&createInfos=Y&struct=auswahlBaum&nodeID=…\|studiengang:stg=<Nr>,pversion=<Jahr>,kzfa=<Kennz.>` | Tabelle `summary="Liste der Stammdaten des Studierenden"` (Zeilen `th.mod_header` + `td.mod_n_basic`: Name, Geburtsdatum/-ort, Abschluss, Fach, Matrikelnummer, Anschrift) – **nicht übernehmen**; darunter die Leistungstabelle(n); Links „PDF-Notenspiegel zum Drucken“ / „PDF-Übersicht: Leistungen“ |
| Studienverlauf | `state=notenspiegelStudent&next=studienverlauf.vm&nextdir=qispos/studienverlauf/student&verlauf=y` | nicht geöffnet |
| Meine Bescheinigungen | `state=change&type=1&moduleParameter=studentReportsMenu&next=menu.vm&subdir=qissos/reports` | PDF-Links mit `state=verpublish`: „Studienzeit- / Immatrikulationsbescheinigung / Bescheinigung nach § 9 …“ und englische Fassung „Certificate of study period and enrolment …“; Hinweis „verifizierbar“ (`state=verify`) |

Beobachtungen:

- Zum Zeitpunkt der Prüfung waren **noch keine Leistungen verbucht**: Die Seite „Leistungen“ enthielt nur die
  Stammdaten-Tabelle. Der Aufbau der Leistungstabelle ist deshalb noch nicht am echten Konto gesehen. Der Parser
  arbeitet wie `qis.py` über die Kopfzeilen (Prüfungsnr., Prüfungstext, Semester, Note, Status, Credits, Versuch,
  Datum) und muss mit „keine Leistungen“ umgehen; die Stammdaten-Tabelle wird übersprungen.
- Ablauf in der App: Anmeldung in einer Webansicht auf der echten QIS-Seite (Passwort bleibt beim Nutzer), danach den
  Links folgen (Mein Studium → Notenspiegel → Abschluss → Studiengang → Leistungen), Tabellen lesen,
  Bescheinigungen nur auf ausdrücklichen Wunsch erzeugen (jeder `verpublish`-Aufruf erstellt ein Dokument).
- „Prüfungsanmeldung/-abmeldung“ nicht automatisiert öffnen oder bedienen.

## Stud.IP JSON:API (studip.uni-hannover.de/jsonapi.php/v1)

Mit der Sitzung aus der Anmeldung, Kopfzeile `Accept: application/vnd.api+json`.

| Abfrage | Ergebnis (Aufbau) |
|---|---|
| `users/me` | `data.id` (Nutzer-ID für die weiteren Abfragen) |
| `users/{id}/courses?page[limit]=100&include=start-semester` | Kurse ohne Folgeseite (19 Kurse); Attribute `course-number`, `title`, `subtitle`, `course-type` (Zahl, gesehen: 1, 3, 7, 10, 35, 40), `description`, `location`, `miscellaneous`; Beziehungen u. a. `start-semester`, `end-semester`, `events`, `folders`, `file-refs`, `memberships`, `status-groups` |
| `courses/{id}/events?page[limit]=200` | Typ `course-events`; Attribute `title`, `description`, `start`/`end` (ISO 8601 mit Zeitzone, z. B. `2026-10-26T09:00:00+01:00`), `type` (gesehen: `"1"`), `categories` (gesehen: immer `"Sitzung"`), `location`, `is-cancelled`, `mkdate`, `chdate`, `recurrence`; einzelne Kurse haben mehr als 200 Termine → `links.next` folgen |
| `users/{id}/schedule` | 102 × `seminar-cycle-dates` und 1 × `schedule-entries`; Attribute `title`, `description`, `start`/`end` (`HH:MM`), `weekday` (1–5 = Mo–Fr), `color`, `recurrence` (`FREQ`, `INTERVAL`, `DTSTART`, `UNTIL`, `EXDATES`), `locations` (Liste); Beziehung `owner` → `courses` |

Folgerungen für den nativen Stundenplan-Import (fehlte bisher, siehe docs/IPAD-STUDIP-SYNC.md):

- `seminar-cycle-dates` liefern die **regelmäßigen Kurszeiten direkt**: Wochentag, Beginn/Ende, Rhythmus
  (`INTERVAL` 1 = wöchentlich, 2 = alle zwei Wochen), Zeitraum (`DTSTART`/`UNTIL`) und Ausfälle (`EXDATES`). Der
  Python-Abgleich leitet das bisher aus den Einzelterminen ab und nutzt nur `schedule-entries` (eigene Einträge).
- Mehrere `seminar-cycle-dates` je Kurs sind parallele Übungsgruppen → Gruppenauswahl wie im Web
  („N Fächer mit parallelen Übungsgruppen“ in Uni & Noten, Importvorschau mit unsicheren Zeilen).
- Die Art (Vorlesung, Übung, Tutorium …) steht nicht in `categories` (immer „Sitzung“), sondern ergibt sich wie in
  `studip_sync.py`/`timetable.py` aus Kurstitel und `course-type`.
- Abgesagte Einzeltermine: `is-cancelled` bei `course-events` bzw. `EXDATES` bei den Kurszeiten.

## Opencast-Aufzeichnungen (LUH-Plugin, Stand 25.10.2026)

Die Videos liegen **nicht** in den Datei-Ordnern der JSON:API, sondern im LUH-Opencast-Modul. Gelesen im Browser,
festgehalten ist nur der Aufbau (keine Titel, Namen oder Kennungen). Nachbau mit erfundenen Werten:
`packages/shared-contracts/fixtures/opencast/`, Parser `OpencastParser` im Kern (derselbe HTML-Leser wie für QIS).

| Seite | Aufbau |
|---|---|
| `plugins.php/opencastpluginluh/media/index?cid=<Kurs-ID>` | serverseitig gerendertes HTML, Sitzung = Stud.IP-Cookie; Tabelle `table.media-table`, je Video `tr.media-table-row` mit `id` (UUID oder kurze Kennung wie `Xyzab-12345-6789`) |
| Spalte Vorschau | `div.thumb-container` mit `style="background-image:url('…')"` (Bild auf dem Opencast-Host) |
| Spalte Titel | `td div.media-table-infos > div > a` (Text = Titel, Link = Player), darunter optional ein `div` mit der Beschreibung |
| Laufzeit | `td.media-table-duration`, `data-sort-value="HH:MM:SS"` |
| Autor/-in | `td.media-table-lecturer`, „-“ = keine Angabe |
| Erstellt am | `td.media-table-created`, `data-sort-value` = Unix-Zeit, Text `dd.mm.yyyy` |
| Aktionen | „Zum Video“ → `plugins.php/opencastpluginluh/media/player/<id>?cid=…`; „Download: 1080p/720p/480p“ → direkte MP4-Links auf dem Opencast-Host (ohne Signatur-Parameter, nicht jede Fassung bei jedem Video); „Problem melden“ (`mailto:`) |
| Kurs ohne Reiter | dieselbe Seite antwortet mit **HTTP 500** („navigation item '/course/opencast/index' not found“) – heißt „kein Opencast“, kein Fehler; im Kursüberblick `dispatch.php/course/overview?cid=…` fehlt dann der Navigationslink „Aufzeichnungen“ |
| Kurs mit Reiter ohne Videos | Tabelle mit leerem `tbody` |

Folgerungen für die App: je gewähltem Kurs eine Anfrage an `media/index` (Kurse ohne Opencast höchstens alle
7 Tage), nur bei einer unklaren Antwort zusätzlich der Kursüberblick – und daraus „kein Opencast“ nur, wenn die
Antwort sicher der Kursüberblick ist (Adresse `course/overview`, Kursnavigation mit `cid` des Kurses), nie aus einer
Zwischenseite mit HTTP 200; ein Kurs mit Reiter wird nur durch die Meldung „navigation item … not found“ zu „kein
Opencast“; Anmeldeseite statt Inhalt = Sitzung abgelaufen.
BigBlueButton-Räume (Meetings) enthalten an der LUH keine Aufzeichnungen und werden nicht gelesen.
Ob der Opencast-Host die MP4-Links ohne Anmeldung ausliefert, ist noch nicht am Gerät gemessen; die App fällt bei
401/403 auf die Player-Seite in der Webansicht zurück. Videos gehören den Lehrenden: nur privat ansehen, nicht teilen.
