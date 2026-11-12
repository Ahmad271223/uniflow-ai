# Stud.IP-Studiengruppen (erfundene Antworten)

Alle Werte erfunden. Studiengruppen liefert die JSON:API in `users/{id}/courses` wie jeden Kurs, nur mit der
Veranstaltungsart der Studiengruppe (`course-type`, Stud.IP-Standard 99, Klasse „Studiengruppen“), ohne
Veranstaltungsnummer und meist mit Endsemester „unbegrenzt“ (`end-semester` mit `data: null`). Welche Nummer die LUH
vergibt, ist nur mit einem echten Konto mit Studiengruppe prüfbar. Geprüft von `StudIPStudyGroupsTests` (Kern) und
`StudyGroupsAppTests` (App).

| Datei | Abfrage | Inhalt |
| --- | --- | --- |
| `users-courses.json` | `users/{id}/courses?page[limit]=100&include=start-semester,end-semester` | Vorlesung und Übung (Art 1 und 3, mit Nummer), zwei Studiengruppen (Art 99, ohne Nummer, unbegrenzt; eine aus einem früheren Semester) |
| `users-schedule.json` | `users/{id}/schedule` | Kurszeit der Vorlesung (Montag 10:00) und ein wöchentliches Treffen der Studiengruppe (Mittwoch 18:00) |
