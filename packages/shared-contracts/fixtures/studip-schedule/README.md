# Stud.IP-Stundenplan (erfundene Antworten)

Antworten der Stud.IP-JSON:API im Aufbau von `docs/QIS-STUDIP-STRUKTUR.md`, alle Werte erfunden (keine echten
Kurse, Räume oder Kennungen). Geprüft von Swift (`StudIPScheduleStoreTests` im Kern, `TimetableLocalAppTests` in
der App): Abruf, Ablage in der lokalen Datenbank und Übernahme in den Stundenplan wie `auto_import`.

| Datei | Abfrage | Inhalt |
| --- | --- | --- |
| `users-courses.json` | `users/{id}/courses?page[limit]=100&include=start-semester` | fünf Kurse mit `course-type`, darunter eine Übung und „Begrüßung der Erstsemester“ (sonstiges) |
| `users-schedule.json` | `users/{id}/schedule` | Kurszeiten (`seminar-cycle-dates`) mit Rhythmus, Zeitraum und Ausfällen, drei parallele Übungsgruppen eines Kurses, eigene Einträge (`schedule-entries`, auch Sonntag und einer ohne Uhrzeit) |
| `course-events-c-ana-1.json`, `-2.json` | `courses/c-ana/events?page[limit]=200` und die Folgeseite | Einzeltermine zu einer Kurszeit, ein abgesagter, eine Klausur außerhalb der Kurszeiten, ein Eintrag ohne ID |
| `course-events-c-sem.json` | `courses/c-sem/events?page[limit]=200` | Kurs ohne Kurszeiten: drei Termine, die wie auf dem PC zu einer Serie werden |
| `kalender/` | `users/{id}/schedule`, `users/{id}/courses…`, `courses/{id}/events?page[limit]=200`, `users/{id}/events.ics` | eigener Stud.IP-Kalender (`StudIPCalendarTests`, `StudIPCalendarAppTests`). Enthalten sind: zwei Übungsgruppen (eine eigene), eine Gruppe in zwei Zeiträumen (nur der zweite eigen), eine Kurszeit „Hauptveranst.“ neben vier Gruppen, ein Kurs ohne Kalendertermine, vier Fragestunden je Woche, dieselbe Zeit in zwei Räumen (nur einer eigen), eine vergangene Einführung, ein Ausfall mit „(fällt aus)“ und ein eigener Kalendertermin ohne Kurs |

Einträge, die sich nicht lesen lassen (ohne ID, ohne Uhrzeit, Kurszeit ohne Kurs), zählt der Abruf und nennt sie in
der Zusammenfassung („2 Stundenplan-Einträge aus Stud.IP nicht lesbar“ für diese Fixture); ihr gespeicherter Stand
bleibt, und ein Kurs mit Terminen ohne ID verliert keine gespeicherten Termine (externer Prüfbericht 382, 421, 425,
`StudIPScheduleIntegrityTests`).
