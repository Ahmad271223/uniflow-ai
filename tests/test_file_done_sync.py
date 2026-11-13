"""Haken "erledigt" je Datei im Geraete-Abgleich (Auftrag 13.11.2026, Teil 2): zwei Geraete eines Kontos (PC mit
eigener Datenbank, "iPad" direkt per G2, Dienst per ASGI wie tests/test_sync_client.py). Ein Stand je Datei
(`files.status`), fuer den Abgleich als Einstellung `file_done:<ID>`; der neuere Stand gewinnt; ein Haken von einem
anderen Geraet schliesst hier die offenen Lernaufgaben zur Datei; abgewaehlte Faecher: Haken ja, Planung nein."""
import json

from conftest import asgi_call
from test_sync_client import FILE, ipad_pull, ipad_push, two_devices  # noqa: F401  (Fixture `two_devices`)

KEY = "file_done:" + FILE


def _local(app, method, path, body=None, status=200):
    st, _, raw = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None)
    assert st == status, (method, path, st, raw[:300])
    return json.loads(raw) if raw else None


def _setup_module(open_task=True):
    from app import db
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, semester) VALUES ('Mathematik I', 'WiSe 26/27')").lastrowid
        conn.execute("UPDATE courses SET module_id=? WHERE id='kurs-1'", (mid,))
        pid = conn.execute("INSERT INTO study_packages(date, module_id, title, planned_minutes) VALUES (date('now'), ?, 'Mathe', 60)", (mid,)).lastrowid
        tid = conn.execute("INSERT INTO study_tasks(package_id, type, file_id, title, status) VALUES (?, 'uebung', ?, 'Blatt 1', ?)",
                           (pid, FILE, "geplant" if open_task else "erledigt")).lastrowid
        test = conn.execute("INSERT INTO study_tasks(package_id, type, file_id, title, status) VALUES (?, 'test', ?, 'Wochentest', 'geplant')",
                            (pid, FILE)).lastrowid
    return mid, pid, tid, test


def _state(tid=None):
    from app import db
    with db.cursor() as conn:
        f = db.row(conn, "SELECT status FROM files WHERE id=?", (FILE,))["status"]
        mark = (db.row(conn, "SELECT value FROM settings WHERE key=?", (KEY,)) or {}).get("value")
        t = db.row(conn, "SELECT status FROM study_tasks WHERE id=?", (tid,))["status"] if tid else None
    return f, mark, t


def _mark_on_service(app, ipad):
    changes, _ = ipad_pull(app, ipad)
    return next((s for s in changes.get("settings", []) if s["key"] == KEY), None)


def test_tick_goes_to_the_other_device_and_back(two_devices):
    app, ipad = two_devices
    from app import db, sync_client
    mid, _, tid, test = _setup_module()
    # Haken am PC: Datei erledigt, Aufgabe erledigt (Test nicht), Eintrag fuer den Abgleich
    assert _local(app, "POST", f"/api/modules/{mid}/done", {"file_ids": [FILE], "done": True}) == {"changed": [FILE], "tasks": 1}
    assert _state(tid) == ("erledigt", "1", "erledigt")
    with db.cursor() as conn:
        assert db.row(conn, "SELECT status FROM study_tasks WHERE id=?", (test,))["status"] == "geplant", "Wochentest bleibt"
        assert "file_done:" + FILE not in db.get_settings(conn), "kein Eintrag in den Einstellungen der Oberflaeche"
    assert sync_client.run()["ok"]
    m = _mark_on_service(app, ipad)
    assert m and m["value"] == "1", "Haken im Dienst"

    # das iPad nimmt den Haken weg; nach dem naechsten Abgleich ist er am PC auch weg
    r = ipad_push(app, ipad, [{"entity": "settings", "id": KEY, "base_version": m["sync_version"],
                               "updated_at": "2099-01-01T00:00:00.000Z", "data": {"value": "0"}}])
    assert r["results"][0]["status"] == "applied", r
    assert sync_client.run()["ok"]
    assert _state()[:2] == ("gelesen", "0")

    # wieder abgehakt auf dem iPad, am PC inzwischen eine neue offene Aufgabe: die schliesst der Abgleich
    with db.cursor() as conn:
        conn.execute("UPDATE study_tasks SET status='geplant' WHERE id=?", (tid,))
    m = _mark_on_service(app, ipad)
    ipad_push(app, ipad, [{"entity": "settings", "id": KEY, "base_version": m["sync_version"],
                           "updated_at": "2099-01-01T00:00:01.000Z", "data": {"value": "1"}}])
    out = sync_client.run()
    assert out["ok"], out
    assert _state(tid) == ("erledigt", "1", "erledigt")
    with db.cursor() as conn:
        note = db.row(conn, "SELECT note FROM task_history WHERE task_id=? ORDER BY id DESC LIMIT 1", (tid,))["note"]
    assert note == "Auf einem anderen Gerät abgehakt"
    again = sync_client.run()
    assert again["ok"], again


def test_newer_state_wins(two_devices):
    """Beide Geraete aendern denselben Haken, bevor sie abgleichen: der neuere Stand gewinnt"""
    app, ipad = two_devices
    from app import db, sync_client
    mid, *_ = _setup_module()

    def pc(done, stamp):
        _local(app, "POST", f"/api/modules/{mid}/done", {"file_ids": [FILE], "done": done})
        with db.cursor() as conn:
            conn.execute("UPDATE settings SET sync_updated_at=? WHERE key=?", (stamp, KEY))

    def ipad_sets(value):
        m = _mark_on_service(app, ipad)
        r = ipad_push(app, ipad, [{"entity": "settings", "id": KEY, "base_version": m["sync_version"],
                                   "updated_at": "2026-11-13T00:00:00.000Z", "data": {"value": value}}])
        assert r["results"][0]["status"] == "applied", r

    pc(True, "2020-01-01T00:00:00.000Z")
    assert sync_client.run()["ok"]                       # Dienst: '1'
    # das iPad nimmt den Haken weg (jetzt), der PC hatte ihn frueher (2020) noch einmal gesetzt: das iPad gewinnt
    ipad_sets("0")
    pc(False, "2020-01-01T00:00:01.000Z")
    pc(True, "2020-01-01T00:00:02.000Z")
    assert sync_client.run()["ok"]
    assert _state()[:2] == ("gelesen", "0"), "der neuere Stand (iPad) gewinnt"
    assert _mark_on_service(app, ipad)["value"] == "0"
    # jetzt setzt das iPad den Haken, der PC nimmt ihn spaeter weg: der PC gewinnt
    ipad_sets("1")
    pc(True, "2100-01-01T00:00:00.000Z")
    pc(False, "2100-01-01T00:00:01.000Z")
    assert sync_client.run()["ok"]
    assert _state()[:2] == ("gelesen", "0"), "der neuere Stand (PC) gewinnt"
    assert _mark_on_service(app, ipad)["value"] == "0"


def test_dashboard_task_done_shows_tick_and_reopen_removes_it(two_devices):
    """Lernstand: Aufgabe in "Heute für dich geplant" erledigt -> Haken an der Datei (und im Abgleich); wieder geoeffnet
    -> Haken weg"""
    app, _ = two_devices
    from app import db
    mid, _, tid, _ = _setup_module()
    _local(app, "POST", f"/api/tasks/{tid}/status", {"status": "erledigt"})
    assert _state(tid) == ("erledigt", "1", "erledigt")
    d = _local(app, "GET", f"/api/modules/{mid}")
    assert next(f for f in d["files"] if f["id"] == FILE)["status"] == "erledigt"
    _local(app, "POST", f"/api/tasks/{tid}/status", {"status": "geplant"})
    assert _state(tid) == ("gelesen", "0", "geplant")
    with db.cursor() as conn:
        assert db.get_settings(conn).get(KEY) is None


def test_document_status_uses_the_same_state(two_devices):
    """Status im Dokument (PC-Ansicht, PATCH /api/files): erledigt an/aus wie der Haken"""
    app, _ = two_devices
    _, _, tid, _ = _setup_module()
    _local(app, "PATCH", f"/api/files/{FILE}", {"status": "erledigt"})
    assert _state(tid) == ("erledigt", "1", "erledigt")
    _local(app, "PATCH", f"/api/files/{FILE}", {"status": "neu"})
    assert _state(tid) == ("neu", "0", "geplant")


def test_deselected_subject_tick_without_planning(two_devices):
    """plan_modules_off: Haken ja; Haken weg oeffnet keine Aufgaben wieder (keine Planung)"""
    app, _ = two_devices
    from app import db
    mid, _, tid, _ = _setup_module()
    with db.cursor() as conn:
        conn.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('plan_modules_off', ?)", (json.dumps(["Mathematik I"]),))
    assert _local(app, "POST", f"/api/modules/{mid}/done", {"file_ids": [FILE], "done": True})["tasks"] == 1
    assert _local(app, "POST", f"/api/modules/{mid}/done", {"file_ids": [FILE], "done": False}) == {"changed": [FILE], "tasks": 0}
    assert _state(tid) == ("gelesen", "0", "erledigt")


def test_file_loaded_later_gets_the_tick():
    """Haken kam per Abgleich an, bevor die Datei hier geladen war: die Datei bekommt ihn beim Laden"""
    from app import db
    with db.cursor() as conn:
        conn.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('file_done:spaet-1', '1')")
        conn.execute("INSERT INTO files(id, course_id, name, status) VALUES ('spaet-1', '__user__', 'Spaet.pdf', 'neu')")
        assert db.row(conn, "SELECT status FROM files WHERE id='spaet-1'")["status"] == "erledigt"
        conn.execute("DELETE FROM files WHERE id='spaet-1'")
        conn.execute("DELETE FROM settings WHERE key='file_done:spaet-1'")
