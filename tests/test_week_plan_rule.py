"""Lernplan nach der Regel des Inhabers vom 30.10.2026 (app/study.py): ein Tag bekommt nur den Stoff seiner Lehrwoche,
dazu den Rest eines Skripts nach dem Marker ("Vorlesung bis hier") der Vorwoche; nach einem Abgleich plant
`auto_plan_week` die laufende Woche; die Testaufgabe im Plan oeffnet in Faechern mit Markern den gemeinsamen
Wochentest (app/weekly.py). Jeder Test hat eine eigene Datenbank und eine feste Uhr (Montag, 26.10.2026 = Lehrwoche 3).
Alle Werte erfunden."""
import json
from datetime import date, datetime, timedelta

import pytest

from conftest import asgi_call


@pytest.fixture()
def fresh(app, tmp_path, monkeypatch):
    from app import db, study
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "woche.db")
    db.init_db()
    monkeypatch.setattr(study, "today", lambda: date(2026, 10, 26))
    return app


def call(app, method, path, body=None):
    status, _, raw = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None)
    return status, json.loads(raw) if raw else None


def _ts(week: int, day: int = 1) -> int:
    """Unix-Zeit in Lehrwoche `week` (Vorlesungsbeginn Montag, 12.10.2026), `day` Tage nach Montag, 10 Uhr"""
    return int((datetime(2026, 10, 12, 10) + timedelta(weeks=week - 1, days=day)).timestamp())


def _module(weeks=(1, 2, 3)) -> int:
    """Ein Modul mit Vorlesung (45 min) und Uebungsblatt (60 min) je Lehrwoche"""
    from app import db
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Testfach Woche', '#123456', 0, '2026-10-01T09:00:00')").lastrowid
        conn.execute("INSERT INTO courses(id, title, subject, kind, module_id, created_at) VALUES ('kw', 'Testfach Woche', 'Testfach Woche', 'vorlesung', ?, '2026-10-01')", (mid,))
        conn.execute("INSERT INTO courses(id, title, kind, created_at) VALUES ('kx', 'Begrüßung', 'sonstiges', '2026-10-01')")
        conn.execute("INSERT INTO files(id, course_id, name, chdate) VALUES ('fx', 'kx', 'Willkommen.pdf', ?)", (_ts(1),))
        for w in weeks:
            conn.execute("INSERT INTO files(id, course_id, name, chdate, studip_folder) VALUES (?, 'kw', ?, ?, 'Vorlesung')", (f"v{w}", f"VL0{w}.pdf", _ts(w)))
            conn.execute("INSERT INTO files(id, course_id, name, chdate, studip_folder) VALUES (?, 'kw', ?, ?, 'Übungsblätter')", (f"u{w}", f"Blatt {w}.pdf", _ts(w, 2)))
    return mid


def _marker(mid: int, file_id: str, page: int, count: int, week: int, **extra) -> None:
    from app import db
    row = {"module_id": mid, "file_id": file_id, "doc_version": "v1", "page": page, "page_count": count,
           "lecture_date": (date(2026, 10, 12) + timedelta(weeks=week - 1, days=1)).isoformat(), "week_no": week,
           "created_at": "2026-10-20T12:00:00", **extra}
    with db.cursor() as conn:
        conn.execute(f"INSERT INTO lecture_markers({','.join(row)}) VALUES ({','.join('?' * len(row))})", list(row.values()))


def _titles(app, start: str, end: str) -> list[list[str]]:
    st, cal = call(app, "GET", f"/api/calendar?start={start}&end={end}")
    return [[t["title"] for p in d["packages"] for t in p["tasks"]] for d in cal["days"]]


def test_plan_takes_only_the_current_lehrwoche(fresh):
    """KW 44 (Lehrwoche 3): nur VL03 und Blatt 3, nicht die offenen Vorlesungen der Wochen 1 und 2 (vorher kamen die
    aeltesten zuerst dran). Das freie Fenster plant die aelteren weiter."""
    _module()
    st, r = call(fresh, "POST", "/api/calendar/generate", {"start": "2026-10-26", "days": 7})
    assert (st, r["created"]) == (200, 1)
    assert [t for d in _titles(fresh, "2026-10-26", "2026-11-01") for t in d] == ["VL03.pdf", "Blatt 3.pdf"]
    # eine Woche spaeter ohne neue Unterlagen: nichts (die Woche 3 ist geplant, Woche 4 hat noch nichts)
    st, r = call(fresh, "POST", "/api/calendar/generate", {"start": "2026-11-02", "days": 7})
    assert (r["created"], r["message"]) == (0, "Keine offenen Vorlesungen oder Übungen für diese Woche.")
    # freies Fenster: die aelteste offene Einheit (Lehrwoche 1)
    st, r = call(fresh, "POST", "/api/calendar/generate", {"start": "2026-10-27", "window_start": "16:00", "window_end": "18:00"})
    assert r["created"] == 1
    assert "VL01.pdf" in _titles(fresh, "2026-10-27", "2026-10-27")[0]


def test_marker_rest_comes_into_the_next_week(fresh):
    """Endet der Marker der Vorwoche mitten im Skript, steht der Rest vorne im Paket dieser Woche, anteilige Dauer;
    geloeschte, zu pruefende, fremde und Kursmarker zaehlen nicht, ein bis zur letzten Seite markiertes Skript hat
    keinen Rest, und derselbe Rest steht je Lehrwoche nur einmal im Plan."""
    mid = _module()
    _marker(mid, "v2", 20, 50, 2)
    _marker(mid, "v2", 10, 50, 2)                                  # aelterer, kleinerer Marker derselben Woche
    _marker(mid, "v1", 30, 30, 1)                                  # VL01 ganz behandelt
    _marker(mid, "u2", 3, 8, 2)                                    # Uebungsblatt: kein Skript
    _marker(mid, "v2", 45, 50, 2, deleted_at="2026-10-21T08:00:00")
    _marker(mid, "v2", 48, 50, 2, needs_review=1)
    _marker(mid, "v2", 49, 50, 2, user_id="jemand")
    _marker(mid, "v2", 47, 50, 2, scope="course")
    st, r = call(fresh, "POST", "/api/calendar/generate", {"start": "2026-10-27", "days": 1})
    assert (st, r["created"]) == (200, 2)                          # 132 Minuten: zwei Pakete zu hoechstens 120
    st, cal = call(fresh, "GET", "/api/calendar?start=2026-10-27&end=2026-10-27")
    tasks = [t for p in cal["days"][0]["packages"] for t in p["tasks"]]
    assert [(t["title"], t["file_id"], t["est_minutes"]) for t in tasks] == [
        ("VL02.pdf · S. 21–50", "v2", 27), ("VL03.pdf", "v3", 45), ("Blatt 3.pdf", "u3", 60)]

    # derselbe Rest nicht doppelt: angefangen, dann den naechsten Tag ersetzen
    call(fresh, "POST", f"/api/tasks/{tasks[0]['id']}/status", {"status": "in_bearbeitung"})
    from app import db
    with db.cursor() as conn:
        conn.execute("INSERT INTO files(id, course_id, name, chdate, studip_folder) VALUES ('z3', 'kw', 'Zusatz 3.pdf', ?, 'Übungsblätter')", (_ts(3, 3),))
    st, r = call(fresh, "POST", "/api/calendar/generate", {"start": "2026-10-28", "days": 1, "replace": True})
    assert r["created"] == 1
    assert _titles(fresh, "2026-10-28", "2026-10-28") == [["Zusatz 3.pdf"]]

    # Marker dieser Woche: der Rest reicht nur bis dorthin; der Rest danach gehoert in die Woche 4
    _marker(mid, "v2", 40, 50, 3)
    _marker(mid, "v3", 12, 30, 3)
    from app import study
    with db.cursor() as conn:
        units = study._units(conn, mid, set(), 4, frozenset())
    assert [(f["id"], f["pages"]) for f in units[0]["vorlesungen"]] == [("v2", [41, 50]), ("v3", [13, 30])]
    with db.cursor() as conn:                                      # Woche 5: kein Marker in Woche 4, kein Rest
        assert study._units(conn, mid, set(), 5, frozenset()) == []
    with db.cursor() as conn:
        rest = study._marker_rest(conn, mid, 3, study.semester_start(conn), study._file_rows(conn, mid), frozenset())
    assert [(f["id"], f["pages"], f["est_minutes"]) for f in rest] == [("v2", [21, 40], 18)]
    # erledigte Datei: kein Rest
    with db.cursor() as conn:
        conn.execute("UPDATE files SET status='erledigt' WHERE id='v2'")
        units = study._units(conn, mid, set(), 4, frozenset())
    assert [f["id"] for f in units[0]["vorlesungen"]] == ["v3"]


def test_auto_plan_week_after_sync(fresh, monkeypatch):
    """Nach dem Abgleich: mit neuen Dateien oder ohne automatisches Paket in dieser Woche die Woche ab heute planen
    (ersetzt nur nicht begonnene automatische Pakete), sonst nichts; aus mit auto_plan = 0"""
    from app import db, study
    _module()
    monkeypatch.setattr(study, "today", lambda: date(2026, 10, 28))      # Mittwoch
    with db.cursor() as conn:
        r = study.auto_plan_week(conn, 0)                              # noch kein automatisches Paket
    assert r["created"] == 1
    assert [len(d) for d in _titles(fresh, "2026-10-26", "2026-11-01")] == [0, 0, 2, 0, 0, 0, 0]
    with db.cursor() as conn:
        assert study.auto_plan_week(conn, 0) is None                   # geplant, keine neuen Dateien
        conn.execute("INSERT INTO files(id, course_id, name, chdate, studip_folder) VALUES ('u3b', 'kw', 'Blatt 3b.pdf', ?, 'Übungsblätter')", (_ts(3, 2),))
    with db.cursor() as conn:
        r = study.auto_plan_week(conn, 1)
    assert r["created"] == 2                                       # 165 Minuten: zwei Pakete
    assert [t for d in _titles(fresh, "2026-10-26", "2026-11-01") for t in d] == ["VL03.pdf", "Blatt 3.pdf", "Blatt 3b.pdf"]
    call(fresh, "PUT", "/api/settings", {"auto_plan": False})
    with db.cursor() as conn:
        assert study.auto_plan_week(conn, 3) is None


def test_plan_test_task_opens_the_marker_test(fresh):
    """Testaufgabe im Plan, Fach mit Markern: ohne Plan und vor der Veroeffentlichung 409 mit Grund, danach der Versuch
    am gemeinsamen Wochentest (immer derselbe); ohne Marker bleibt es beim klassischen Weg"""
    from app import db, weekly
    mid = _module(weeks=(3,))
    call(fresh, "PUT", "/api/settings", {"tests_per_subject": "1"})
    st, r = call(fresh, "POST", "/api/calendar/generate", {"start": "2026-10-27", "days": 1})
    st, cal = call(fresh, "GET", "/api/calendar?start=2026-10-27&end=2026-10-27")
    task = [t for p in cal["days"][0]["packages"] for t in p["tasks"] if t["type"] == "test"][0]
    with db.cursor() as conn:
        assert weekly.task_test(conn, mid, 3) is None                    # ohne Marker: klassischer Wochentest
    _marker(mid, "v3", 10, 30, 2)                                  # Marker nur in Woche 2
    st, r = call(fresh, "POST", f"/api/tasks/{task['id']}/start-test")
    assert (st, r["detail"]) == (409, "Für die Lehrwoche 3 ist noch kein Vorlesungsstoff markiert („Vorlesung bis hier“ im Skript setzen).")
    _marker(mid, "v3", 20, 30, 3)                                  # Marker in Woche 3, der Takt hat noch nicht geplant
    st, r = call(fresh, "POST", f"/api/tasks/{task['id']}/start-test")
    assert (st, r["detail"]) == (409, "Der gemeinsame Wochentest der Lehrwoche 3 wird gerade geplant. Bitte später erneut versuchen.")
    plan = {"module_id": mid, "week_no": 3, "scope": "personal", "scope_key": "k1", "user_id": "local", "coverage": "{}",
            "lecture_end": "2026-10-27T11:30:00", "publish_at": "2026-10-28T11:30:00", "deadline_at": "2026-10-30T11:30:00", "status": "geplant"}
    with db.cursor() as conn:
        pid = conn.execute(f"INSERT INTO wt_plans({','.join(plan)}) VALUES ({','.join('?' * len(plan))})", list(plan.values())).lastrowid
    st, r = call(fresh, "POST", f"/api/tasks/{task['id']}/start-test")
    assert (st, r["detail"]) == (409, "Der gemeinsame Wochentest der Lehrwoche 3 erscheint voraussichtlich am 28.10. um 11:30 Uhr.")
    with db.cursor() as conn:
        did = conn.execute("""INSERT INTO wt_defs(kind, plan_id, module_id, week_no, scope_key, material_hash, title, duration_min, questions, status, published_at)
                              VALUES ('wochentest', ?, ?, 3, 'k1', 'h1', 'Grenzwerte', 30, '[]', 'veroeffentlicht', '2026-10-28T11:30:00')""", (pid, mid)).lastrowid
        conn.execute("UPDATE wt_plans SET status='veroeffentlicht', def_id=? WHERE id=?", (did, pid))
    st, r = call(fresh, "POST", f"/api/tasks/{task['id']}/start-test")
    assert st == 200
    tid = r["test_id"]
    st, t = call(fresh, "GET", f"/api/tests/{tid}")
    assert (t["def_id"], t["title"]) == (did, "Lehrwoche 3: Grenzwerte")
    assert call(fresh, "POST", f"/api/tasks/{task['id']}/start-test") == (200, {"test_id": tid})
    st, cal = call(fresh, "GET", "/api/calendar?start=2026-10-27&end=2026-10-27")
    assert [(t["status"], t["test_id"]) for p in cal["days"][0]["packages"] for t in p["tasks"] if t["type"] == "test"] == [("in_bearbeitung", tid)]
