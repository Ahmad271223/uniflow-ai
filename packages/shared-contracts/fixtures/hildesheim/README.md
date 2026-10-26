# Fixtures Uni Hildesheim

Erwartungswerte für Learnweb, CAS und LSF aus der Python-Referenz (`tools/gen-hildesheim-fixture.py`, Prüfung mit
`--check`). Python (`tests/test_hildesheim.py`) und der Swift-Kern (`HildesheimFixtureTests`, `LearnwebTests`,
`UniStoreTests`) prüfen dieselben Dateien.

## Herkunft

- `lsf-course.ics` und `lsf-plan.ics` haben das Format eines echten LSF-Exports (Stand 26.10.2026): `PRODID` von HIS,
  `DTSTART` am Semesterbeginn, Wochentag nur in `BYDAY`, mehrere `BYDAY`, `EXDATE` mit Komma am Ende, Kommas im Titel
  als `\,`, leere `LOCATION`. **Alle Inhalte sind erfunden**: Räume (`TG.1.0.01`, `TC.T.1.01`), Veranstaltungsnummern
  (9xxx), Titel, Lehrperson („Muster“) und die UID (`1:1`). Echte Raum-, Veranstaltungs- oder Personendaten gehören
  nie in diesen Ordner; ein neuer Rohexport wird vor dem Einchecken so verfremdet, dass nur das Format bleibt.
- `learnweb-course-contents.json` folgt der Antwort von `core_course_get_contents` (Moodle), mit erfundenen Kursen
  und Dateien.
- `expected.json` entsteht nur aus dem Generator, nie von Hand.
