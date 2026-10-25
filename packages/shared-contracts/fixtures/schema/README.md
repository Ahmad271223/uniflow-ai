# Schema-Fixtures (lokale Datenbank)

Erzeugt mit der Python-Referenz, nicht von Hand ändern:

```
python tools/gen-swift-schema.py      # Sources/UniFlowCore/Store/SchemaSQL.swift aus app.db.SCHEMA
python tools/gen-schema-fixture.py    # schema.json und legacy.json aus app.db.init_db()
```

Beide Werkzeuge kennen `--check` (nichts schreiben, Exitcode 1, wenn veraltet). `init_db()` läuft dabei nur gegen
Dateien in einem Temp-Ordner, nie gegen `data/`.

| Datei | Inhalt | Geprüft von |
| --- | --- | --- |
| `schema.json` | neue Datenbank: Tabellen, Spalten (Typ, Default, NotNull, PK), Fremdschlüssel, Indizes, Standardeinstellungen, Pseudokurs `__user__`, Standardsemester | Swift (`SQLiteStoreTests`) |
| `legacy.json` | älterer Stand mit erfundenen Zeilen (`setup_sql`) und das Ergebnis von `init_db()` darauf | Swift (`SQLiteStoreTests`) |

Nach jeder Änderung an `app/db.py` (Schema, `add_col`, Standardwerte) beide Werkzeuge ausführen und
`Store/Migrations.swift` angleichen; die Swift-Tests zeigen jede Abweichung.
