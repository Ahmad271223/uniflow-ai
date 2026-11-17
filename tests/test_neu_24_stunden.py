""""Neu" nur 24 Stunden (Auftrag des Inhabers 17.11.2026: "wenn etwas laenger als 24 Std in der App ist, automatisch nicht
mehr neu"). Eine Regel fuer alle Stellen (`study.new_file_sql`): nie geoeffnet UND vor hoechstens 24 Stunden eingetragen
(`first_seen`). Derselbe Ablauf wie Neu24StundenTests.swift im iPad-Kern; 1:1 verglichen wird in den gemeinsamen
Fixtures (library-files.json, study-modules.json, timetable-logic.json)."""
import json
import os
import time
from datetime import date

import pytest
from conftest import asgi_call

NOW = "2026-11-17T13:20:05"


def _call(app, method, path, body=None, status=200):
    st, _, raw = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None)
    assert st == status, (method, path, st, raw[:300])
    return json.loads(raw) if raw else None


@pytest.fixture
def clock(monkeypatch):
    """Uhr des Dienstes (`db.now_iso`) einfrieren und weiterstellbar machen"""
    from app import db
    state = {"now": NOW}
    monkeypatch.setattr(db, "now_iso", lambda: state["now"])
    return state


def _setup(p):
    """Ein Modul mit vier nie als gelesen markierten Dateien: 23 Stunden alt, 25 Stunden alt, 23 Stunden alt aber
    geoeffnet, ohne Eintragezeit"""
    from app import db
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES (?, '#175ee8', 97, 't')", (f"Neu24-{p}",)).lastrowid
        conn.execute("INSERT INTO courses(id, title, subject, kind, active, module_id, created_at) VALUES (?,?,?, 'vorlesung', 1, ?, 't')",
                     (f"{p}-c", f"Neu24-{p}", f"Neu24-{p}", mid))
        for fid, first_seen, seen in [("jung", "2026-11-16T14:20:05", 0), ("alt", "2026-11-16T12:20:05", 0),
                                      ("offen", "2026-11-16T14:20:05", 1), ("ohne", None, 0)]:
            conn.execute("INSERT INTO files(id, course_id, name, chdate, first_seen, status, seen_by_user) VALUES (?,?,?,?,?, 'neu', ?)",
                         (f"{p}-{fid}", f"{p}-c", f"Vorlesung {fid}.pdf", 1_794_000_000, first_seen, seen))
    return mid


def _new(files, p):
    return sorted(f["id"] for f in files if f["id"].startswith(p + "-") and f.get("is_new") == 1)


def test_grenze_ist_24_stunden(clock, monkeypatch):
    from app import study
    assert study.NEW_FILE_HOURS == 24
    assert study.new_since() == "2026-11-16T13:20:05"
    assert study.new_file_sql("2026-11-16T13:20:05") == "(f.seen_by_user=0 AND f.first_seen IS NOT NULL AND f.first_seen>='2026-11-16T13:20:05')"
    assert study.new_file_sql() == study.new_file_sql("2026-11-16T13:20:05")
    # wirkliche 24 Stunden ueber die Zeitumstellung (25.10.2026): 14:30 Winterzeit - 24 h = 15:30 Sommerzeit (wie der iPad-Kern)
    saved = os.environ.get("TZ")
    monkeypatch.setenv("TZ", "Europe/Berlin")
    time.tzset()
    try:
        clock["now"] = "2026-10-25T14:30:05"
        assert study.new_since() == "2026-10-24T15:30:05"
    finally:
        if saved is None:
            monkeypatch.delenv("TZ")
        else:
            monkeypatch.setenv("TZ", saved)
        time.tzset()


def test_alle_stellen_sagen_dasselbe(app, clock):
    from app import db, timetable
    p = "n24a"
    mid = _setup(p)
    want = [f"{p}-jung"]
    # Moduldetail: Zaehler und Dateizeilen (auch in den Wochen)
    d = _call(app, "GET", f"/api/modules/{mid}")
    assert d["new_count"] == 1
    assert len(d["files"]) == 4 and all(f["is_new"] in (0, 1) for f in d["files"])
    assert _new(d["files"], p) == want
    in_weeks = [f for w in d["weeks"] for k in ("vorlesungen", "uebungen", "loesungen", "skripte", "klausuren", "sonstiges") for f in w[k]]
    assert len(in_weeks) == 4 and _new(in_weeks, p) == want
    assert all(f["status"] == "neu" for f in d["files"]), "der Lernstand bleibt, wie er ist"
    # Modulkarte
    card = next(m for m in _call(app, "GET", "/api/modules") if m["id"] == mid)
    assert card["new_count"] == 1 and card["file_count"] == 4
    # Uebersicht
    dash = _call(app, "GET", "/api/dashboard")
    assert [f["id"] for f in dash["new_files"] if f["id"].startswith(p + "-")] == want
    assert next(m for m in dash["modules"] if m["id"] == mid)["new_count"] == 1
    assert [f["id"] for f in _call(app, "GET", "/api/overview")["new_files"] if f["id"].startswith(p + "-")] == want
    # Kurse
    course = next(c for c in _call(app, "GET", "/api/courses") if c["id"] == f"{p}-c")
    assert course["new_count"] == 1 and course["file_count"] == 4
    # Bibliothek
    lib = [f for f in _call(app, "GET", "/api/library")["files"] if f["id"].startswith(p + "-")]
    assert len(lib) == 4 and all(f["is_new"] in (0, 1) for f in lib)
    assert _new(lib, p) == want
    # Unterlagen am Termin
    with db.cursor() as conn:
        mats = timetable.materials_for_event(conn, {"module_id": mid}, date(2026, 11, 17))
    assert len(mats) == 4 and _new(mats, p) == want


def test_genau_an_der_grenze(app, clock):
    from app import db
    p = "n24g"
    with db.cursor() as conn:
        conn.execute("INSERT INTO courses(id, title, kind, active, created_at) VALUES (?, 'Neu24 Grenze', 'vorlesung', 1, 't')", (f"{p}-c",))
        for fid, first_seen in [("genau", "2026-11-16T13:20:05"), ("sekunde", "2026-11-16T13:20:04"), ("leer", "")]:
            conn.execute("INSERT INTO files(id, course_id, name, chdate, first_seen, status) VALUES (?,?,?,?,?, 'neu')",
                         (f"{p}-{fid}", f"{p}-c", f"{fid}.pdf", 1_794_000_000, first_seen))
    lib = _call(app, "GET", "/api/library")["files"]
    assert _new(lib, p) == [f"{p}-genau"], "genau 24 Stunden: noch neu; eine Sekunde aelter oder leeres first_seen: nicht mehr"


def test_nach_24_stunden_verschwindet_neu_ohne_zutun(app, clock):
    from app import db
    p = "n24v"
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Neu24-weg', '#175ee8', 96, 't')").lastrowid
        conn.execute("INSERT INTO courses(id, title, subject, kind, active, module_id, created_at) VALUES (?, 'Neu24-weg', 'Neu24-weg', 'vorlesung', 1, ?, 't')",
                     (f"{p}-c", mid))
        conn.execute("INSERT INTO files(id, course_id, name, chdate, first_seen, status) VALUES (?,?, 'a.pdf', 1794000000, '2026-11-16T12:30:00', 'neu')",
                     (f"{p}-a", f"{p}-c"))
    clock["now"] = "2026-11-17T12:00:00"
    assert _call(app, "GET", f"/api/modules/{mid}")["new_count"] == 1, "23,5 Stunden alt: neu"
    clock["now"] = "2026-11-17T13:00:00"          # eine Stunde spaeter: niemand hat etwas getan
    d = _call(app, "GET", f"/api/modules/{mid}")
    assert d["new_count"] == 0 and _new(d["files"], p) == []
    assert [f["id"] for f in _call(app, "GET", "/api/dashboard")["new_files"] if f["id"].startswith(p + "-")] == []
    assert _new(_call(app, "GET", "/api/library")["files"], p) == []
    with db.cursor() as conn:
        row = db.row(conn, "SELECT status, seen_by_user, first_seen FROM files WHERE id=?", (f"{p}-a",))
    assert row == {"status": "neu", "seen_by_user": 0, "first_seen": "2026-11-16T12:30:00"}, "nichts wird als gelesen markiert"


def test_oeffnen_nimmt_neu_sofort_weg(app, clock):
    p = "n24o"
    mid = _setup(p)
    _call(app, "POST", f"/api/files/{p}-jung/opened", {})
    d = _call(app, "GET", f"/api/modules/{mid}")
    assert d["new_count"] == 0 and _new(d["files"], p) == []
