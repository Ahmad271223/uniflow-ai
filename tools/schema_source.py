"""Gemeinsamer Zugang der Fixture-Werkzeuge (tools/gen-*.py ausser gen-parity.py) zu app/db.py und der
Python-Referenz: frische Datenbank (`SchemaSource.fresh_db`), eingefrorene Uhr (`SchemaSource.freeze`), Zeitzone
Berlin (`berlin_time`), Tabellen nach einem Lauf (`dump_tables`) und Schreiben oder Pruefen (`write_or_check`).

app/config.py legt beim Import DATA_DIR/LOG_DIR an und setzt DB_PATH darin. Damit die Werkzeuge nie die echte
Datenbank in data/ anfassen, werden beide Ordner vor dem Import ueber LERNAPP_DATA_DIR/LERNAPP_LOG_DIR auf einen
Temp-Ordner umgelenkt (wie tests/conftest.py).
"""
from __future__ import annotations

import os
import shutil
import sqlite3
import sys
import tempfile
import time
from contextlib import contextmanager
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
        """Die CREATE-Anweisung, die scriptsearch.ensure_table wirklich ausfuehrt (aufgezeichnet, nicht abgeschrieben).
        Danach prueft ensure_table die Spalten (PRAGMA) und haengt die Suchform an aeltere Tabellen an; das spiegelt
        Migrations.swift (Spalte `search`)."""
        class Recorder:
            def __init__(self) -> None:
                self.sql: list[str] = []

            def execute(self, sql, *args):
                self.sql.append(sql)
                return []                      # PRAGMA table_info einer leeren Aufzeichnung: keine Spalten

        rec = Recorder()
        self.scriptsearch.ensure_table(rec)
        expected = ["PRAGMA table_info(page_texts)", "ALTER TABLE page_texts ADD COLUMN search TEXT"]
        if len(rec.sql) != 3 or "CREATE TABLE IF NOT EXISTS page_texts" not in rec.sql[0] or rec.sql[1:] != expected:
            raise RuntimeError(f"scriptsearch.ensure_table hat sich geaendert: {rec.sql!r}")
        return rec.sql[0]

    def use_db(self, path: Path) -> None:
        """app.db.connect() liest DB_PATH bei jedem Aufruf aus dem Modul: hier auf eine eigene Datei umbiegen."""
        if not path.resolve().is_relative_to(self.tmp.resolve()):
            raise RuntimeError(f"Nur Dateien im Temp-Ordner: {path}")
        self.db.DB_PATH = path

    def fresh_db(self, name: str) -> Path:
        """Frische Datenbank <Temp>/<name>.db (eine alte samt -wal/-shm entfernt), angelegt mit init_db wie beim Start"""
        path = self.tmp / f"{name}.db"
        for suffix in ("", "-wal", "-shm"):
            path.with_name(path.name + suffix).unlink(missing_ok=True)
        self.use_db(path)
        self.db.init_db()
        return path

    def freeze(self, today, now_iso, now=None) -> None:
        """Uhr der Referenz einfrieren: date.today() in server.py und study.py liefert today(), db.now_iso() liefert
        now_iso() und mit `now` auch datetime.now() in server.py now(). Die Funktionen werden bei jedem Aufruf gefragt
        (weiterstellbare Uhr)."""
        from datetime import date, datetime

        from app import server, study

        class FrozenDate(date):
            @classmethod
            def today(cls):
                d = today()
                return cls(d.year, d.month, d.day)

        server.date = FrozenDate
        study.date = FrozenDate
        self.db.now_iso = now_iso
        if now is not None:
            class FrozenDateTime(datetime):
                @classmethod
                def now(cls, tz=None):
                    n = now()
                    return n if tz is None else n.astimezone(tz)

            server.datetime = FrozenDateTime

    def cleanup(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)


@contextmanager
def berlin_time():
    """Zeitzone Europe/Berlin wie der PC-Server (datetime.fromtimestamp, timestamp()); danach wie vorher."""
    saved = os.environ.get("TZ")
    os.environ["TZ"] = "Europe/Berlin"
    time.tzset()
    try:
        yield
    finally:
        if saved is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = saved
        time.tzset()


def dump_tables(path: Path, queries: dict[str, str]) -> dict:
    """Tabellen nach einem Lauf: {Name: Zeilen der Abfrage als dict}"""
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    try:
        return {name: [dict(r) for r in conn.execute(sql)] for name, sql in queries.items()}
    finally:
        conn.close()


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
