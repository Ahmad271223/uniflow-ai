"""Dateien frueherer Semester (03.11.2026, wie die iPad-App: OlderSemestersTests): Kurse frueherer Semester bleiben als
Kurs bekannt, ihre Dateien kommen nur auf Wunsch (Frage nach dem ersten Abgleich, "Dateien laden" in der Bibliothek,
Einstellung). Erfundene Kurse und Antworten, nie ein echter Abruf."""
import json
from datetime import date

import pytest

from conftest import asgi_call

TODAY = date(2026, 11, 3)                 # WiSe 2026/27


@pytest.fixture
def older(app, monkeypatch):
    """Drei Kurse: aktuell, SoSe 2026 und WiSe 2024/25 (beide frueher); leere Merker."""
    from app import db, study
    monkeypatch.setattr(study, "today", lambda: TODAY)
    ids = ("ol-neu", "ol-sose", "ol-wise", "ol-ohne")
    with db.cursor() as conn:
        # Kurse anderer Tests (gemeinsame Datenbank der Testlaeufe) stoeren die Zaehlung: waehrend des Tests als aktiv, danach zurueck
        parked = [r["id"] for r in db.rows(conn, "SELECT id FROM courses WHERE COALESCE(active, 1)=0 AND id NOT LIKE 'ol-%'")]
        conn.executemany("UPDATE courses SET active=1 WHERE id=?", [(i,) for i in parked])
        for t in ("older_semester_choice", "older_semester_courses"):
            conn.execute(f"DROP TABLE IF EXISTS {t}")
        conn.execute("DELETE FROM files WHERE course_id LIKE 'ol-%'")
        conn.execute("DELETE FROM courses WHERE id LIKE 'ol-%'")
        for cid, title, sem, active in [("ol-neu", "Neu", "WiSe 2026/27", 1), ("ol-sose", "Sommer", "SoSe 2026", 0),
                                        ("ol-wise", "Winter alt", "WiSe 2024/25", 0), ("ol-ohne", "Ohne Semester", "", 0)]:
            conn.execute("INSERT INTO courses(id, title, semester, kind, active, test_minutes, created_at) VALUES (?,?,?,?,?,?,?)",
                         (cid, title, sem, "vorlesung", active, 90, "2026-10-01"))
        for fid, cid, path in [("ol-f1", "ol-sose", "/x/a.pdf"), ("ol-f2", "ol-sose", None), ("ol-f3", "ol-wise", "/x/c.pdf")]:
            conn.execute("INSERT INTO files(id, course_id, name, size, chdate, status, kind, first_seen, local_path) VALUES (?,?,?,?,?,?,?,?,?)",
                         (fid, cid, fid + ".pdf", 10, 1, "neu", "pdf", "2026-10-01", path))
    yield ids
    with db.cursor() as conn:
        conn.executemany("UPDATE courses SET active=0 WHERE id=?", [(i,) for i in parked])
        conn.execute("DELETE FROM files WHERE course_id LIKE 'ol-%'")
        conn.execute("DELETE FROM courses WHERE id LIKE 'ol-%'")
        for t in ("older_semester_choice", "older_semester_courses"):
            conn.execute(f"DROP TABLE IF EXISTS {t}")


def _get(app, path):
    st, _, body = asgi_call(app, "GET", path)
    return st, json.loads(body or b"null")


def _post(app, path, data):
    st, _, body = asgi_call(app, "POST", path, body=json.dumps(data))
    return st, json.loads(body or b"null")


def test_overview_groups_older_courses_by_semester_newest_first(app, older):
    st, o = _get(app, "/api/older-semesters")
    assert st == 200
    assert o["choice"] is None and o["current"] == "WiSe 2026/27"
    assert [s["label"] for s in o["semesters"]] == ["SoSe 2026", "WiSe 2024/25"], "neuestes zuerst, ohne Semester gehoert nicht dazu"
    sose = o["semesters"][0]["courses"][0]
    assert sose == {"id": "ol-sose", "title": "Sommer", "files": 2, "downloaded": 1, "requested": False, "loaded": False}
    assert "ol-neu" not in json.dumps(o) and "ol-ohne" not in json.dumps(o)


def test_question_is_open_until_a_choice_is_stored(app, older):
    from app import db, older_semesters as os_
    with db.cursor() as conn:
        assert os_.needs_question(conn) is True
    st, r = _post(app, "/api/older-semesters/choice", {"choice": "current"})
    assert (st, r) == (200, {"choice": "current"})
    with db.cursor() as conn:
        assert os_.needs_question(conn) is False and os_.choice(conn) == "current"
    assert _post(app, "/api/older-semesters/choice", {"choice": "viel"})[0] == 422
    assert _get(app, "/api/older-semesters")[1]["choice"] == "current"


def test_no_question_without_older_courses(app, older):
    from app import db, older_semesters as os_
    with db.cursor() as conn:
        conn.execute("UPDATE courses SET active=1 WHERE id LIKE 'ol-%'")
        assert os_.needs_question(conn) is False
        assert os_.groups(conn) == []


def test_pending_follows_choice_and_requests(app, older, monkeypatch):
    from app import db, older_semesters as os_, older_semesters_api
    started = []
    monkeypatch.setattr(older_semesters_api, "start_loading", lambda: started.append(1) or {"started": True, "note": "x"})
    with db.cursor() as conn:
        # seit 05.11.2026 (app/sync_order.py): Vorgabe "Nur WLAN", Stufe (d) holt alles Fruehere im Hintergrund
        assert os_.mode(conn) == "wifi" and os_.pending(conn) == {"ol-sose", "ol-wise"}
        os_.set_mode(conn, "off", "2026-11-03T09:00:00")
        assert os_.choice(conn) == "current" and os_.pending(conn) == set(), "Aus: nur Vorgemerktes"
    st, r = _post(app, "/api/older-semesters/request", {"course_ids": ["ol-sose", "ol-neu", "unbekannt", "ol-sose"]})
    assert st == 200 and r["requested"] == 1, "nur Kurse frueherer Semester zaehlen, ein Kurs nur einmal"
    assert started == [1], "Abgleich wird gestartet"
    assert _post(app, "/api/older-semesters/request", {"course_ids": []}) [1] == {"requested": 0}
    assert started == [1], "ohne Kurs kein Abgleich"
    with db.cursor() as conn:
        assert os_.pending(conn) == {"ol-sose"}
        os_.set_choice(conn, "all", "2026-11-03T10:00:00")
        assert os_.pending(conn) == {"ol-sose", "ol-wise"}
        os_.mark_loaded(conn, ["ol-sose"], "2026-11-03T10:05:00")
        assert os_.pending(conn) == {"ol-wise"}, "geladene Kurse fragt der naechste Abgleich nicht erneut ab"
        os_.set_choice(conn, "current", "2026-11-03T10:06:00")
        assert os_.pending(conn) == set()
        os_.request(conn, ["ol-sose"], "2026-11-03T11:00:00")
        assert os_.pending(conn) == {"ol-sose"}, "erneutes Laden holt auch einen fertigen Kurs wieder"
    c = _get(app, "/api/older-semesters")[1]["semesters"][0]["courses"][0]
    assert c["requested"] is True and c["loaded"] is False


def test_user_activated_old_course_is_not_older(app, older):
    from app import db, older_semesters as os_
    with db.cursor() as conn:
        conn.execute("UPDATE courses SET active=1, active_custom=1 WHERE id='ol-sose'")
        assert [c["id"] for c in os_.courses(conn)] == ["ol-wise"]


def test_finish_marks_only_courses_with_all_files(app, older):
    from app import db, older_semesters as os_
    with db.cursor() as conn:
        assert os_.finish(conn, ["ol-sose", "ol-wise"], "2026-11-03T12:00:00") == ["ol-wise"], "ol-f2 fehlt noch"
        assert {c["id"]: c["loaded"] for c in os_.courses(conn)} == {"ol-sose": False, "ol-wise": True}


def test_course_files_for_inactive_course(app, older):
    st, files = _get(app, "/api/older-semesters/courses/ol-sose/files")
    assert st == 200 and [f["id"] for f in files] == ["ol-f1", "ol-f2"]
    assert [f["downloaded"] for f in files] == [1, 0]
    assert _get(app, "/api/older-semesters/courses/gibt-es-nicht/files")[0] == 404
    ids = {f["id"] for f in _get(app, "/api/library")[1]["files"]}
    assert not ids & {"ol-f1", "ol-f2", "ol-f3"}, "die Bibliothek zeigt nur aktive Kurse; frueher Semester stehen extra"


def test_load_route_starts_only_when_something_is_pending(app, older, monkeypatch):
    from app import db, older_semesters as os_, older_semesters_api
    started = []
    monkeypatch.setattr(older_semesters_api, "start_loading", lambda: started.append(1) or {"started": True, "note": "x"})
    with db.cursor() as conn:
        os_.set_mode(conn, "off", "2026-11-03T09:00:00")
    st, r = _post(app, "/api/older-semesters/load", {})
    assert st == 200 and r["started"] is False and started == []
    with db.cursor() as conn:
        os_.set_choice(conn, "all", "2026-11-03T10:00:00")
    assert _post(app, "/api/older-semesters/load", {})[1]["started"] is True and started == [1]


# --- Abgleich -------------------------------------------------------------------------------------------------------

def _file(fid, name="a.pdf"):
    return {"id": fid, "name": name, "size": 1, "mime": "application/pdf", "author": None, "chdate": 1,
            "download_url": f"https://x/{fid}", "folder": None}


def test_studip_sync_loads_only_wanted_older_courses(app, older, monkeypatch, tmp_path):
    from app import db, older_semesters as os_, studip_sync
    monkeypatch.setattr(studip_sync, "FILES_DIR", tmp_path)
    monkeypatch.setattr(studip_sync, "_files_dir", lambda: tmp_path)
    monkeypatch.setattr(studip_sync, "log", lambda m: None)
    monkeypatch.setattr(studip_sync.time, "sleep", lambda s: None)
    asked = []
    monkeypatch.setattr(studip_sync, "fetch_files", lambda page, cid: asked.append(cid) or [_file(f"neu-{cid}")])
    monkeypatch.setattr(studip_sync, "fetch_folder_paths", lambda page, cid: {})

    def dl(page, url, target, size=0):
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"%PDF")

    monkeypatch.setattr(studip_sync, "download", dl)
    courses = [{"id": c, "title": c, "number": None, "semester": ""} for c in ("ol-neu", "ol-sose", "ol-wise")]
    new: list = []
    with db.cursor() as conn:
        os_.set_mode(conn, "off", "2026-11-03T09:00:00")
        assert studip_sync.sync_older_files(None, conn, courses, "2026-11-03", new) == 0, "nichts gewuenscht, nichts geladen"
        os_.request(conn, ["ol-sose"], "2026-11-03T10:00:00")
        assert studip_sync.sync_older_files(None, conn, courses, "2026-11-03", new) == 1
        assert asked == ["ol-sose"], "weder der aktuelle noch der nicht gewuenschte fruehere Kurs"
        assert new == ["neu-ol-sose"]
        assert {c["id"]: c["loaded"] for c in os_.courses(conn)} == {"ol-sose": False, "ol-wise": False}, \
            "ol-f2 (Altbestand ohne Datei) fehlt noch: der Kurs gilt nicht als fertig"
        conn.execute("DELETE FROM files WHERE id='ol-f2'")
        assert studip_sync.sync_older_files(None, conn, courses, "2026-11-03", new) == 1
        assert [c["id"] for c in os_.courses(conn) if c["loaded"]] == ["ol-sose"]
        assert studip_sync.sync_older_files(None, conn, courses, "2026-11-03", new) == 0, "geladen: nicht erneut abfragen"


def test_studip_sync_keeps_a_course_open_when_the_folder_listing_fails(app, older, monkeypatch, tmp_path):
    from app import db, older_semesters as os_, studip_sync
    monkeypatch.setattr(studip_sync, "_files_dir", lambda: tmp_path)
    monkeypatch.setattr(studip_sync, "log", lambda m: None)
    monkeypatch.setattr(studip_sync.time, "sleep", lambda s: None)
    monkeypatch.setattr(studip_sync, "fetch_files", lambda page, cid: [_file("neu-x")])
    monkeypatch.setattr(studip_sync, "fetch_folder_paths", lambda page, cid: (_ for _ in ()).throw(RuntimeError("Ordner")))
    monkeypatch.setattr(studip_sync, "download", lambda page, url, target, size=0: (target.parent.mkdir(parents=True, exist_ok=True), target.write_bytes(b"%PDF")))
    with db.cursor() as conn:
        conn.execute("DELETE FROM files WHERE course_id='ol-wise'")
        os_.request(conn, ["ol-wise"], "2026-11-03T10:00:00")
        assert studip_sync.sync_older_files(None, conn, [{"id": "ol-wise", "title": "x", "number": None, "semester": ""}], "2026-11-03", []) == 1
        assert {c["id"]: c["loaded"] for c in os_.courses(conn)}["ol-wise"] is False, "Ordner unvollstaendig: spaeter erneut"


def test_learnweb_sync_older_only_and_full(app, older, monkeypatch, tmp_path):
    from app import db, hildesheim, learnweb, older_semesters as os_, studip_sync
    asked = []

    class Client:
        def files(self, mid):
            asked.append(mid)
            return [{"id": learnweb.file_id(mid, "/", "a.pdf"), "name": "a.pdf", "size": 1, "mime": "application/pdf", "author": None,
                     "chdate": 1, "download_url": f"https://x/pluginfile.php/{mid}/mod_resource/content/1/a.pdf", "folder": None}]

    def fake_dl(page, url, target, token="", size=0):
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"%PDF")

    monkeypatch.setattr(hildesheim, "_download", fake_dl)
    monkeypatch.setattr(studip_sync, "_files_dir", lambda: tmp_path)
    monkeypatch.setattr(studip_sync.time, "sleep", lambda s: None)
    monkeypatch.setattr(hildesheim, "log", lambda m: None)
    lw = [{"id": "ol-lwneu", "moodle_id": 301, "title": "LW neu", "number": None, "semester": "WiSe 2026/27"},
          {"id": "ol-lwalt", "moodle_id": 302, "title": "LW alt", "number": None, "semester": "SoSe 2025"},
          {"id": "ol-lwalt2", "moodle_id": 303, "title": "LW alt 2", "number": None, "semester": "SoSe 2025"}]
    try:
        new: list = []
        with db.cursor() as conn:
            os_.set_mode(conn, "off", "2026-11-03T09:00:00")
        assert hildesheim.sync_learnweb(None, Client(), lw, "", "2026-11-03", new) == 1
        assert asked == [301], "ohne Wunsch nur das aktuelle Semester"
        with db.cursor() as conn:
            os_.request(conn, ["ol-lwalt"], "2026-11-03T10:00:00")
        asked.clear()
        assert hildesheim.sync_learnweb(None, Client(), lw, "", "2026-11-03", new, older_only=True) == 1
        assert asked == [302], "nur der gewuenschte fruehere Kurs"
        with db.cursor() as conn:
            assert {c["id"]: c["loaded"] for c in os_.courses(conn) if c["id"].startswith("ol-lw")} == {"ol-lwalt": True, "ol-lwalt2": False}
            os_.set_choice(conn, "all", "2026-11-03T11:00:00")
        asked.clear()
        assert hildesheim.sync_learnweb(None, Client(), lw, "", "2026-11-03", new) == 1
        assert asked == [301], "voller Abgleich (05.11.2026): nur das aktuelle Semester, fruehere danach in Stufe (d)"
        asked.clear()
        assert hildesheim.sync_learnweb(None, Client(), lw, "", "2026-11-03", new, older_only=True) == 1
        assert asked == [303], "Stufe (d): der noch nicht geladene fruehere Kurs"
    finally:
        with db.cursor() as conn:
            conn.execute("DELETE FROM files WHERE course_id LIKE 'ol-lw%'")
            conn.execute("DELETE FROM courses WHERE id LIKE 'ol-lw%'")


def test_routes_are_registered(app):
    """Im Dienst gilt wie bei jeder /api-Route die Sitzung (tests/test_accounts.py prueft alle Routen)."""
    from app import older_semesters_api
    paths = {r.path for r in older_semesters_api.router.routes}
    assert paths == {"/api/older-semesters", "/api/older-semesters/choice", "/api/older-semesters/mode", "/api/older-semesters/request",
                     "/api/older-semesters/load", "/api/older-semesters/courses/{course_id}/files"}
