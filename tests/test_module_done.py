"""Haken "erledigt" je Datei und ganze Woche im Moduldetail (Auftrag 13.11.2026, `study.set_files_done`). Derselbe
Ablauf wie ModuleDoneTests.swift im Kern: gleicher Stand wie die Lernpakete, nur Dateien des Moduls."""
import json

from conftest import asgi_call


def _call(app, method, path, body=None, status=200):
    st, _, raw = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None)
    assert st == status, (method, path, st, raw[:300])
    return json.loads(raw) if raw else None


def _setup(p):
    from app import db
    with db.cursor() as conn:
        m1 = conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Done-Analysis', '#175ee8', 98, 't')").lastrowid
        m2 = conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Done-Physik', '#16a34a', 99, 't')").lastrowid
        conn.execute("INSERT INTO courses(id, title, subject, kind, active, module_id, created_at) VALUES (?, 'Done-Analysis', 'Done-Analysis', 'vorlesung', 1, ?, 't')", (f"{p}-c1", m1))
        conn.execute("INSERT INTO courses(id, title, subject, kind, active, module_id, created_at) VALUES (?, 'Done-Physik', 'Done-Physik', 'vorlesung', 1, ?, 't')", (f"{p}-c2", m2))
        for fid, course, status in [("0", "c1", "neu"), ("1", "c1", "gelesen"), ("2", "c1", "erledigt"), ("fremd", "c2", "neu")]:
            conn.execute("INSERT INTO files(id, course_id, name, chdate, status) VALUES (?,?,?,?,?)", (f"{p}-{fid}", f"{p}-{course}", f"{fid}.pdf", 1_792_000_000, status))
        pid = conn.execute("INSERT INTO study_packages(date, module_id, title, status, created_at) VALUES (date('now'), ?, 'Analysis', 'geplant', 't')", (m1,)).lastrowid
        tids = [conn.execute("INSERT INTO study_tasks(package_id, type, file_id, title, status) VALUES (?, 'vorlesung', ?, ?, ?)", (pid, f"{p}-{fid}", fid, st)).lastrowid
                for fid, st in [("0", "geplant"), ("1", "uebersprungen"), ("2", "erledigt"), ("fremd", "geplant")]]
    return m1, tids


def _state(p, tids):
    from app import db
    with db.cursor() as conn:
        files = [f"{r['id'][len(p) + 1:]}={r['status']}" for r in db.rows(conn, "SELECT id, status FROM files WHERE id LIKE ? ORDER BY id", (f"{p}-%",))]
        tasks = [db.row(conn, "SELECT status FROM study_tasks WHERE id=?", (t,))["status"] for t in tids]
        notes = [r["note"] for r in db.rows(conn, f"SELECT note FROM task_history WHERE task_id IN ({','.join('?' * len(tids))}) ORDER BY id", tids)]
    return files, tasks, notes


def test_tick_and_untick_share_state_with_study_tasks(app):
    mid, tids = _setup("mt")
    p = "mt"
    r = _call(app, "POST", f"/api/modules/{mid}/done", {"file_ids": [f"{p}-0", f"{p}-1", f"{p}-fremd"], "done": True})
    assert r == {"changed": [f"{p}-0", f"{p}-1"], "tasks": 1}
    files, tasks, _ = _state(p, tids)
    assert files == ["0=erledigt", "1=erledigt", "2=erledigt", "fremd=neu"]
    assert tasks == ["erledigt", "uebersprungen", "erledigt", "geplant"]
    d = _call(app, "GET", f"/api/modules/{mid}")
    assert {f["id"] for f in d["files"] if f["status"] == "erledigt"} == {f"{p}-0", f"{p}-1", f"{p}-2"}

    r = _call(app, "POST", f"/api/modules/{mid}/done", {"file_ids": [f"{p}-0", f"{p}-1", f"{p}-2"], "done": False})
    assert r == {"changed": [f"{p}-0", f"{p}-1", f"{p}-2"], "tasks": 2}
    files, tasks, notes = _state(p, tids)
    assert files == ["0=gelesen", "1=gelesen", "2=gelesen", "fremd=neu"]
    assert tasks == ["geplant", "uebersprungen", "geplant", "geplant"]
    assert notes == ["Im Modul abgehakt", "Haken im Modul entfernt", "Haken im Modul entfernt"]


def test_rejects_bad_input(app):
    mid, tids = _setup("mb")
    p = "mb"
    _call(app, "POST", f"/api/modules/{mid}/done", {"file_ids": [f"{p}-0"]}, status=400)
    _call(app, "POST", f"/api/modules/{mid}/done", {"file_ids": [], "done": True}, status=400)
    _call(app, "POST", "/api/modules/99999/done", {"file_ids": [f"{p}-0"], "done": True}, status=404)
    assert _state(p, tids)[0] == ["0=neu", "1=gelesen", "2=erledigt", "fremd=neu"]
