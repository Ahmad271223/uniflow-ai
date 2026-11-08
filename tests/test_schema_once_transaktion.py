"""db.schema_once liess die Verbindung in einer offenen Transaktion zurueck (08.11.2026, gefunden ueber einen wackelnden
Community-Test unter Last). Folge: alle Lesezugriffe danach lagen auf einem alten Stand, und der erste Schreibzugriff
bekam bei gleichzeitigem Schreiben eines anderen Kontos sofort 'database is locked' (SQLite wartet beim Hochstufen
eines Lese-Snapshots nicht, busy_timeout greift nicht). Betroffen: alle Datenbanken, die schema_once nutzen."""
import sqlite3
import threading

import pytest


def test_schema_once_leaves_no_open_transaction(tmp_path):
    from app import db
    p = tmp_path / "x.db"
    conn = sqlite3.connect(p)
    db.schema_once(conn, "probe", p, lambda c: (c.execute("CREATE TABLE IF NOT EXISTS t(a)"), c.execute("INSERT INTO t VALUES (1)")))
    assert not conn.in_transaction, "Schema-Arbeit muss festgeschrieben sein, bevor der Aufrufer liest"
    conn.close()
    assert sqlite3.connect(p).execute("SELECT COUNT(*) FROM t").fetchone()[0] == 1


@pytest.mark.parametrize("modul", ["community", "accounts"])
def test_cursor_starts_outside_a_transaction(app, modul):
    import importlib
    m = importlib.import_module(f"app.{modul}")
    for _ in range(2):                        # auch wenn schema_once wegen geaenderter Datei erneut laeuft
        with m.cursor() as conn:
            assert not conn.in_transaction, f"{modul}.cursor beginnt in einer offenen Transaktion"


def test_community_write_after_concurrent_commit_waits_instead_of_locked(app):
    """Nachgestellt: A oeffnet und liest, B schreibt und schreibt fest, A schreibt -> vorher sofort 'database is locked'."""
    from app import community
    with community.cursor() as c0:
        c0.execute("CREATE TABLE IF NOT EXISTS probe_tx(a)")
    errors = []
    with community.cursor() as a:
        a.execute("SELECT COUNT(*) FROM probe_tx").fetchone()

        def b():
            try:
                with community.cursor() as conn:
                    conn.execute("INSERT INTO probe_tx VALUES (2)")
            except Exception as e:                         # noqa: BLE001
                errors.append(repr(e))
        t = threading.Thread(target=b)
        t.start()
        t.join(5)
        try:
            a.execute("INSERT INTO probe_tx VALUES (1)")
        except sqlite3.OperationalError as e:
            errors.append(repr(e))
    assert errors == [], errors
    with community.cursor() as c:
        assert c.execute("SELECT COUNT(*) FROM probe_tx").fetchone()[0] == 2
