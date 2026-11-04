"""WAL-Modus nur einmal je Datenbankdatei (db.wal_once, 04.11.2026). Vorher schaltete jede Verbindung
`PRAGMA journal_mode=WAL`; auf einer neuen Datei hielten zwei gleichzeitige Verbindungen die Lesesperre und wollten
beide den Dateikopf schreiben - SQLite brach sofort mit 'database is locked' ab (kein busy_timeout fuer den Wechsel).
Je Oeffner: frische Temp-Datei, 2-4 Threads gleichzeitig, 40 Runden; nie 'database is locked', danach WAL."""
import sqlite3
import threading
from contextlib import closing

import pytest

ROUNDS = 40


def _db_connect(monkeypatch, path):
    from app import config, db
    monkeypatch.setattr(db, "DB_PATH", path)
    monkeypatch.setattr(config, "current_user_id", lambda: None)

    def use():
        with closing(db.connect()) as conn:
            conn.execute("SELECT 1").fetchone()
    return use


def _accounts(monkeypatch, path):
    from app import accounts
    monkeypatch.setattr(accounts, "db_path", lambda: path)

    def use():
        with accounts.cursor() as conn:
            conn.execute("SELECT count(*) FROM users").fetchone()
    return use


def _billing(monkeypatch, path):
    from app import accounts, billing
    monkeypatch.setattr(accounts, "db_path", lambda: path)

    def use():
        with closing(billing.connect()) as conn:
            conn.execute("SELECT count(*) FROM entitlements").fetchone()
    return use


def _accounts_and_billing(monkeypatch, path):
    """Zwei Oeffner derselben Datei (accounts.db) abwechselnd: die Sperre gilt je Datei, nicht je Oeffner."""
    a, b = _accounts(monkeypatch, path), _billing(monkeypatch, path)
    n = {"i": 0}
    lock = threading.Lock()

    def use():
        with lock:
            n["i"] += 1
            i = n["i"]
        (a if i % 2 else b)()
    return use


def _community(monkeypatch, path):
    from app import community
    monkeypatch.setattr(community, "db_path", lambda: path)

    def use():
        with community.cursor() as conn:
            conn.execute("SELECT 1").fetchone()
    return use


def _test_library(monkeypatch, path):
    from app import test_library
    monkeypatch.setattr(test_library, "db_path", lambda: path)

    def use():
        with test_library.cursor() as conn:
            conn.execute("SELECT 1").fetchone()
    return use


def _cardshare(monkeypatch, path):
    from app import cardshare, test_library
    monkeypatch.setattr(test_library, "db_path", lambda: path)

    def use():
        with cardshare.cursor() as conn:
            conn.execute("SELECT 1").fetchone()
    return use


OPENERS = {"db.connect": _db_connect, "accounts.cursor": _accounts, "billing.connect": _billing,
           "accounts+billing": _accounts_and_billing, "community.cursor": _community,
           "test_library.cursor": _test_library, "cardshare.cursor": _cardshare}


@pytest.mark.parametrize("name", sorted(OPENERS))
def test_fresh_database_parallel_first_connections(name, tmp_path, monkeypatch):
    for r in range(ROUNDS):
        path = tmp_path / f"r{r}" / "fresh.db"
        path.parent.mkdir()
        use = OPENERS[name](monkeypatch, path)
        threads_n = 2 + r % 3                           # 2, 3, 4 Threads
        barrier = threading.Barrier(threads_n)
        errors: list[str] = []

        def worker():
            try:
                barrier.wait(10)
                use()
            except Exception as e:                      # noqa: BLE001 - jeder Fehler zaehlt, gemeldet unten
                errors.append(f"{type(e).__name__}: {e}")

        threads = [threading.Thread(target=worker) for _ in range(threads_n)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(60)
        assert not errors, f"{name}, Runde {r}, {threads_n} Threads: {errors}"
        with closing(sqlite3.connect(path)) as conn:
            assert conn.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal", f"{name}, Runde {r}: kein WAL"


def test_wal_once_skips_known_file_and_rechecks_replaced(tmp_path):
    """Bekannte Datei: kein PRAGMA mehr je Verbindung; ersetzte Datei (neue Dateinummer) wird wieder umgestellt."""
    from app import db
    path = tmp_path / "x.db"
    with closing(sqlite3.connect(path)) as conn:
        db.wal_once(conn, path)
        assert conn.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
    seen: list[str] = []
    with closing(sqlite3.connect(path)) as conn:
        conn.set_trace_callback(seen.append)
        db.wal_once(conn, path)
    assert not [s for s in seen if "journal_mode" in s], seen
    for suffix in ("", "-wal", "-shm"):
        p = path.with_name(path.name + suffix)
        if p.exists():
            p.unlink()
    with closing(sqlite3.connect(path)) as conn:
        conn.execute("CREATE TABLE t(a)")               # neue Datei mit Inhalt (andere Dateinummer bzw. Zeit)
        conn.commit()
        db.wal_once(conn, path)
        assert conn.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
