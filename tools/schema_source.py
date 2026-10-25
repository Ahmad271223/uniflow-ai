"""Gemeinsamer Zugang der Schema-Werkzeuge (gen-swift-schema.py, gen-schema-fixture.py) zu app/db.py.

app/config.py legt beim Import DATA_DIR/LOG_DIR an und setzt DB_PATH darin. Damit die Werkzeuge nie die echte
Datenbank in data/ anfassen, werden beide Ordner vor dem Import ueber LERNAPP_DATA_DIR/LERNAPP_LOG_DIR auf einen
Temp-Ordner umgelenkt (wie tests/conftest.py).
"""
from __future__ import annotations

import os
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "apps" / "apple" / "Packages" / "UniFlowCore"


class SchemaSource:
    def __init__(self) -> None:
        if "app.config" in sys.modules:
            raise RuntimeError("app.config ist schon geladen: DB_PATH liesse sich nicht mehr umlenken")
        self.tmp = Path(tempfile.mkdtemp(prefix="uniflow-schema-"))
        os.environ["LERNAPP_DATA_DIR"] = str(self.tmp / "data")
        os.environ["LERNAPP_LOG_DIR"] = str(self.tmp / "logs")
        sys.path.insert(0, str(ROOT))
        from app import db, scriptsearch

        if not Path(db.DB_PATH).resolve().is_relative_to(self.tmp.resolve()):
            raise RuntimeError(f"DB_PATH zeigt nicht in den Temp-Ordner: {db.DB_PATH}")
        self.db = db
        self.scriptsearch = scriptsearch

    def page_texts_sql(self) -> str:
        """Die CREATE-Anweisung, die scriptsearch.ensure_table wirklich ausfuehrt (aufgezeichnet, nicht abgeschrieben)."""
        class Recorder:
            def __init__(self) -> None:
                self.sql: list[str] = []

            def execute(self, sql, *args):
                self.sql.append(sql)

        rec = Recorder()
        self.scriptsearch.ensure_table(rec)
        if len(rec.sql) != 1 or "page_texts" not in rec.sql[0]:
            raise RuntimeError(f"scriptsearch.ensure_table hat sich geaendert: {rec.sql!r}")
        return rec.sql[0]

    def use_db(self, path: Path) -> None:
        """app.db.connect() liest DB_PATH bei jedem Aufruf aus dem Modul: hier auf eine eigene Datei umbiegen."""
        if not path.resolve().is_relative_to(self.tmp.resolve()):
            raise RuntimeError(f"Nur Dateien im Temp-Ordner: {path}")
        self.db.DB_PATH = path

    def cleanup(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)


def write_or_check(path: Path, content: str, check: bool) -> bool:
    """Schreibt die Datei oder prueft (--check), ob sie aktuell ist. Rueckgabe: Datei war aktuell."""
    current = path.read_text(encoding="utf-8") if path.exists() else None
    if current == content:
        print(f"aktuell: {path.relative_to(ROOT)}")
        return True
    if check:
        print(f"VERALTET: {path.relative_to(ROOT)}", file=sys.stderr)
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    print(f"geschrieben: {path.relative_to(ROOT)}")
    return False
