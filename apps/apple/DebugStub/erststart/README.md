# Debug-Stub für den ersten Start (nur Debug-Builds)

Erfundene Nachbildungen der Anmeldeseiten und Antworten beider Hochschulen für den Simulator
(`-UFOnboarding login -UFLoginStub <dieser Ordner>`, siehe `Services/DebugUniStub.swift`). Keine echten
Personen, Zugangsdaten oder Uni-Seiten; die PDFs sind kleine Beispiele mit Text (Suche, Lehrwoche).
Erzeugt mit `gen_stub.py` (Scratch der Mac-Sitzung); zum Ändern die Dateien direkt anpassen.

- `studip.html`, `qis.html`, `learnweb.html`, `lsf.html`: Anmeldeseiten; „Anmelden“ führt zu `<dienst>-angemeldet.html`
  (gilt in der App als angemeldet).
- `routes.json`: Antworten der Abgleiche (Stud.IP JSON:API, Opencast, QIS, Learnweb-REST mit `bodyMatch`, LSF).
