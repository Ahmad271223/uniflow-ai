"""Vertraege G5 (Download-Reihenfolge) und G6 (kein Erfolg ohne Wirkung) aus docs/AUFGABENTEILUNG-APPLE-PC.md."""
import json
import os
from pathlib import Path

import pytest
from conftest import asgi_call


# ---------------------------------------------------------------- G6: Aenderung/Loeschung nach ID ohne Treffer -> 404

@pytest.mark.parametrize("method, path, body", [
    ("DELETE", "/api/flashcards/999999", None),
    ("DELETE", "/api/plan/items/999999", None),
    ("DELETE", "/api/tasks/999999", None),
    ("DELETE", "/api/packages/999999", None),
    ("DELETE", "/api/modules/999999", None),
    ("DELETE", "/api/folders/999999", None),
    ("DELETE", "/api/tests/999999", None),
    ("DELETE", "/api/recordings/999999", None),
    ("POST", "/api/files/gibt-es-nicht/favorite", {"favorite": True}),
    ("POST", "/api/files/gibt-es-nicht/opened", {}),
    ("POST", "/api/files/gibt-es-nicht/opened", {"last_page": 3}),
    ("PATCH", "/api/files/gibt-es-nicht", {"status": "gelesen"}),
    ("PATCH", "/api/courses/gibt-es-nicht", {"subject": "x"}),
    ("PATCH", "/api/modules/999999", {"name": "x"}),
    ("PATCH", "/api/tasks/999999", {"title": "x"}),
    ("PATCH", "/api/packages/999999", {"title": "x"}),
    ("PATCH", "/api/folders/999999", {"name": "x"}),
    ("POST", "/api/tasks/999999/status", {"status": "erledigt"}),
    ("POST", "/api/flashcards/999999/review", {"correct": True}),
])
def test_missing_id_is_404_never_ok(app, method, path, body):
    st, _, raw = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None)
    assert st == 404, (method, path, st, raw[:120])
    assert b'"ok"' not in raw and raw != b"null"


def test_existing_id_still_works(app):
    from app import db
    with db.cursor() as conn:
        cur = conn.execute("INSERT INTO flashcards(question, answer, created_at) VALUES ('q', 'a', '2026-10-26')")
        cid = cur.lastrowid
    st, _, raw = asgi_call(app, "POST", f"/api/flashcards/{cid}/review", body=json.dumps({"correct": True}))
    assert st == 200 and json.loads(raw)["box"] == 2
    st, _, raw = asgi_call(app, "DELETE", f"/api/flashcards/{cid}")
    assert st == 200 and json.loads(raw) == {"ok": True}
    st, _, _ = asgi_call(app, "DELETE", f"/api/flashcards/{cid}")
    assert st == 404                                     # zweites Loeschen: nichts mehr da


# ---------------------------------------------------------------- G5: alte Datei bleibt bis zur Bestaetigung

@pytest.fixture
def course_file(app, tmp_path, monkeypatch):
    from app import db, studip_sync
    monkeypatch.setattr(studip_sync, "FILES_DIR", tmp_path / "files")
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('c-g5', 'G5 Kurs', 'vorlesung', 1, '2026-10-26')")
        conn.execute("DELETE FROM files WHERE id='f-g5'")
    yield {"id": "f-g5", "name": "Folien.pdf", "size": 3, "mime": "application/pdf", "author": "", "chdate": 100,
           "download_url": "https://studip.example/file-refs/f-g5/download"}
    with db.cursor() as conn:
        conn.execute("DELETE FROM files WHERE id='f-g5'")
        conn.execute("DELETE FROM courses WHERE id='c-g5'")


def _store(f, download_fn, new=None):
    from app import db, studip_sync
    with db.cursor() as conn:
        studip_sync.store_course_files(conn, {"id": "c-g5", "title": "G5 Kurs"}, [f], {}, download_fn, "2026-10-26",
                                       new if new is not None else [], pause=0)
        return db.row(conn, "SELECT local_path, content_sha256, chdate FROM files WHERE id='f-g5'")


def _writer(content: bytes):
    def dl(url, target: Path, size=0):
        target.parent.mkdir(parents=True, exist_ok=True)
        part = target.with_name(target.name + ".part")
        part.write_bytes(content)
        os.replace(part, target)
    return dl


def test_first_download_then_new_version_replaces_and_cleans_backup(course_file):
    from app import studip_sync
    new: list = []
    row = _store(course_file, _writer(b"alt"), new)
    target = Path(row["local_path"])
    assert target.read_bytes() == b"alt" and new == ["f-g5"]
    row2 = _store({**course_file, "chdate": 200}, _writer(b"neu"), new)
    assert target.read_bytes() == b"neu" and row2["chdate"] == 200 and row2["content_sha256"] != row["content_sha256"]
    assert not target.with_name(target.name + studip_sync.BACKUP_SUFFIX).exists()


def test_db_failure_after_replace_restores_old_file_and_old_row(course_file, monkeypatch):
    from app import studip_sync, testshare

    def boom(p):
        raise OSError("Platte voll")
    original = testshare.file_sha256
    row = _store(course_file, _writer(b"alt"))
    target = Path(row["local_path"])
    monkeypatch.setattr(testshare, "file_sha256", boom)
    row2 = _store({**course_file, "chdate": 200}, _writer(b"neu"))
    assert target.read_bytes() == b"alt", "die alte Datei ist zurueck"
    assert (row2["chdate"], row2["content_sha256"]) == (100, row["content_sha256"]), "Datenbank bleibt bei der alten Fassung"
    assert not target.with_name(target.name + studip_sync.BACKUP_SUFFIX).exists()
    monkeypatch.setattr(testshare, "file_sha256", original)
    row3 = _store({**course_file, "chdate": 200}, _writer(b"neu"))
    assert target.read_bytes() == b"neu" and row3["chdate"] == 200        # naechster Abgleich holt die neue Fassung


def test_failed_download_keeps_old_file(course_file):
    row = _store(course_file, _writer(b"alt"))
    target = Path(row["local_path"])

    def broken(url, target, size=0):
        raise RuntimeError("Netz weg")
    row2 = _store({**course_file, "chdate": 200}, broken)
    assert target.read_bytes() == b"alt" and row2["chdate"] == 100


def test_crash_between_replace_and_db_is_reconciled_on_next_sync(course_file):
    """Absturz simuliert: Datei schon neu, .alt noch da, Datenbank alt -> alte Datei kommt zurueck.
    Umgekehrt (Datenbank schon neu, nur das Aufraeumen fehlte) verschwindet das Backup."""
    from app import db, studip_sync, testshare
    row = _store(course_file, _writer(b"alt"))
    target = Path(row["local_path"])
    backup = target.with_name(target.name + studip_sync.BACKUP_SUFFIX)
    os.link(target, backup)
    target.unlink()
    target.write_bytes(b"neu-unbestaetigt")
    with db.cursor() as conn:
        studip_sync.reconcile_backup(conn, "f-g5", target)
    assert target.read_bytes() == b"alt" and not backup.exists()
    # Fall 2: Datenbank kennt schon die neue Fassung
    target.write_bytes(b"neu")
    os.link(target, backup)
    with db.cursor() as conn:
        conn.execute("UPDATE files SET content_sha256=? WHERE id='f-g5'", (testshare.file_sha256(target),))
        studip_sync.reconcile_backup(conn, "f-g5", target)
    assert target.read_bytes() == b"neu" and not backup.exists()
