# Debug-Stub für den ersten Start (nur Debug-Builds)

Erfundene Nachbildungen der Anmeldeseiten und Antworten beider Hochschulen für den Simulator
(`-UFOnboarding login -UFLoginStub <dieser Ordner>`, siehe `Services/DebugUniStub.swift`). Keine echten
Personen, Zugangsdaten oder Uni-Seiten; die PDFs sind kleine Beispiele mit Text (Suche, Lehrwoche).
Erzeugt mit `gen_stub.py` (Scratch der Mac-Sitzung); zum Ändern die Dateien direkt anpassen.

- `studip.html`, `qis.html`, `learnweb.html`, `lsf.html`: Anmeldeseiten; „Anmelden“ führt zu `<dienst>-angemeldet.html`
  (gilt in der App als angemeldet).
- `routes.json`: Antworten der Abgleiche (Stud.IP JSON:API, Opencast, QIS, Learnweb-REST mit `bodyMatch`, LSF).
- `studip-inbox.json`: zwei erfundene Stud.IP-Nachrichten (eine an zwei Empfänger, eine Systemnachricht); `POST messages`
  antwortet mit 201, damit „Antworten“ im Simulator durchläuft (`docs/NACHRICHTEN-ANTWORTEN-2026-11-05.md`).
- `studip-members-*.json`, `studip-institute-u-stub-doz.json`: erfundene Lehrende der drei Kurse (Dozentin mit
  `beispiel.dozentin@example.org` und Sprechstunde „Mi 14–15 Uhr“ in „1101 - F102“, Tutor ohne Adresse, Programmieren mit
  `programmieren@example.org`) für „Lehrende“ (`docs/LEHRENDE-KONTAKTE-2026-11-06.md`); andere Kurse und Personen leer.
- `qis-bescheinigungen.html`, `qis-bescheinigung.pdf`: „Meine Bescheinigungen“ des QIS wie live gesehen (ein Eintrag,
  verpublish liefert direkt die PDF) mit einer erfundenen Beispiel-PDF für die Seite „Bescheinigungen“
  (`docs/BESCHEINIGUNGEN-2026-11-06.md`).
