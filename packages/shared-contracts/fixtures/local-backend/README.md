# Fixtures des lokalen Backends

Erzeugt mit der Python-Referenz, nicht von Hand ändern:

```
python tools/gen-local-backend-fixture.py          # schreibt alle Dateien
python tools/gen-local-backend-fixture.py --check  # nichts schreiben, Exitcode 1, wenn veraltet
```

`app/server.py` läuft dabei direkt über ASGI gegen Datenbanken in einem Temp-Ordner, nie gegen `data/`. Pfade mit
Netzwerk, KI oder Zugangsdaten (Sync, QIS, Tests erzeugen, `/api/credentials`, `/api/services`) werden nicht
aufgerufen; ihre erwartete lokale Antwort steht in `SAMPLES` im Werkzeug.

| Datei | Inhalt | Geprüft von |
| --- | --- | --- |
| `study-modules.json` | S4: Einordnung ohne KI als Tabellen (`studip_sync.classify` für 59 Kurstitel, `study.effective_type` und `week_hint` für erfundene Dateinamen und Ordner), dazu `str.lower`, die Zeichen, auf die ein Buchstabe mit `re.I` passt, und `difflib`-Ähnlichkeiten (für `PyRegex`/`PyText`/`ModuleGuess`); Semesterwochen an 10 Tagen; Unterlagen zum Termin (`timetable.materials_for_event`) je Modul an 14 Tagen bei 3 eingefrorenen Daten auf der Seed-Datenbank nach `ensure_modules`; eine Folge von Anfragen an die Module-Endpunkte auf einer erfundenen Seed-Datenbank mit eingefrorener Uhr (Zeitzone Europe/Berlin), Antworten von Python und die Tabellen danach | Swift (`StudyClassifyTests`, `StudyWeeksTests`, `EventMaterialsTests`, `LocalModulesEndpointTests`) |
| `app-paths.json` | alle `/api/`-Pfade, die die iPad-App aufruft (grep über `apps/apple/UniFlow`), je mit Beispielanfrage, Form der Python-Antwort bei leerer Datenbank (Typen und Schlüssel) und erwartetem lokalem Status samt Begründung bei Abweichung; `expect.empty_lists` für Listen, die lokal bewusst leer bleiben, `expect.values` für exakt gleiche Werte (z. B. `SERVICES`) | Swift (`LocalBackendCoverageTests`) |
| `timetable-free.json` | freie Zeitfenster und Sperrzeiten aus `/api/timetable/day` und `/week` für mehrere Einstellungen mit erfundenen Werten, ohne Termine und Lernpakete | Swift (`LocalFreeWindowsTests`) |
| `settings-terms.json` | Folge von `GET/PUT /api/settings` und `/api/terms` mit erfundenen Werten, Antworten von Python und die Tabelle `settings` danach (exakter Text von `db.set_setting`) | Swift (`LocalSettingsTermsTests`) |
| `library-files.json` | S3: erfundene Datenbank (Kurse mit und ohne Fach, Stud.IP-Dateien samt Dateien auf der Platte, eigene Dokumente, Ordner, Notizen mit Versionen, Abgleichprotokoll) und eine Folge von gut 110 Anfragen an Bibliothek, Kurse, Dateien, Datei-Inhalt (Kopfzeilen und Bytes), Notizen (Konflikt, Versionen, Wiederherstellen), Bilder, Ordner, Notizbücher und Dokument-Aktionen; Antworten von Python, Tabellen und Dateien danach. Uhr und `uuid4` eingefroren (`Frozen`). `s4_fields` (Einordnung) werden bis S4 nicht verglichen, `expect` nennt bewusste Abweichungen | Swift (`LocalLibraryFixtureTests`) |
| `studip-import.json` | S3: sechs Durchgänge von `studip_sync.run_sync` ohne Netz und Playwright (Kurse, Dateilisten, Ordner, Downloads ersetzt; `classify` erst mit S4): neue, umbenannte, gesperrte, lokal gelöschte und in Stud.IP entfernte Dateien, Nutzeränderungen dazwischen, eine neue Fassung, deren Download scheitert (`fail`) und die der nächste Durchgang lädt, ein Fehlerlauf; zu ladende und geladene Dateien und die Tabellen `courses`, `files`, `sync_log` danach | Swift (`StudIPLibraryTests`) |

Ruft die App einen neuen Pfad auf, bricht das Werkzeug ab, bis er in `SAMPLES` steht.
