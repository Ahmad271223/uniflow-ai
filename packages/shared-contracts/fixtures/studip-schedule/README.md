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
