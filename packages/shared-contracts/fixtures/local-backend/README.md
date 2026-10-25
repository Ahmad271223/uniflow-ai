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
| `app-paths.json` | alle `/api/`-Pfade, die die iPad-App aufruft (grep über `apps/apple/UniFlow`), je mit Beispielanfrage, Form der Python-Antwort bei leerer Datenbank (Typen und Schlüssel) und erwartetem lokalem Status samt Begründung bei Abweichung; `expect.empty_lists` für Listen, die lokal bewusst leer bleiben, `expect.values` für exakt gleiche Werte (z. B. `SERVICES`) | Swift (`LocalBackendCoverageTests`) |
| `timetable-free.json` | freie Zeitfenster und Sperrzeiten aus `/api/timetable/day` und `/week` für mehrere Einstellungen mit erfundenen Werten, ohne Termine und Lernpakete | Swift (`LocalFreeWindowsTests`) |
| `settings-terms.json` | Folge von `GET/PUT /api/settings` und `/api/terms` mit erfundenen Werten, Antworten von Python und die Tabelle `settings` danach (exakter Text von `db.set_setting`) | Swift (`LocalSettingsTermsTests`) |

Ruft die App einen neuen Pfad auf, bricht das Werkzeug ab, bis er in `SAMPLES` steht.
