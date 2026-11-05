"""Zwischenstand beim Erstellen eines Wochentests (05.11.2026, wie die Phasen auf dem iPad): /api/bg meldet "Gemeinsamer Test
wird gesucht …", "Gemeinsamer Test gefunden – wird übernommen …" bzw. "Aufgaben werden erstellt … n Aufgaben"; ein eigener
Test (andere Einstellungen) gibt sich nie als Suche aus."""
from test_week_test_options import _tf, valid_test  # noqa: F401


def run(app, monkeypatch, options, name):
    from app import ai, db, planner, progress
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, color, created_at) VALUES (?, '#123456', '2026-11-05')", (name,)).lastrowid
    lines = []
    monkeypatch.setattr(progress, "report", lines.append)
    monkeypatch.setattr(planner, "_materials_for_test", lambda conn, subject, **kw: [{"id": name, "name": "vl.pdf", "text": "x", "content_sha256": "h-" + name}])
    monkeypatch.setattr(ai, "generate_test", lambda *a, **kw: {"title": "T", "questions": [_tf(i) for i in range(1, 6)]} if (kw.get("options") or {}).get("count") == 5 else valid_test())
    try:
        planner.create_test(name, 15, module_id=mid, week_no=2, auto=False, log=lambda *_: None, options=options)
    finally:
        with db.cursor() as conn:
            conn.execute("DELETE FROM tests WHERE module_id=?", (mid,))
            conn.execute("DELETE FROM modules WHERE id=?", (mid,))
    return lines


def test_standard_test_searches_first_then_generates(app, monkeypatch):
    assert run(app, monkeypatch, None, "Fortschritt Standard") == ["Gemeinsamer Test wird gesucht …", "Aufgaben werden erstellt … 15 Aufgaben"]


def test_own_test_goes_straight_to_the_ai(app, monkeypatch):
    lines = run(app, monkeypatch, {"count": 5, "difficulty": "leicht", "types": ["tf"]}, "Fortschritt Eigen")
    assert lines == ["Aufgaben werden erstellt … 5 Aufgaben"]


def test_found_shared_test_says_so(app, monkeypatch):
    from app import ai, db, planner, progress
    # derselbe Schluessel noch einmal im selben Modul: lokal gefunden -> uebernommen
    name = "Fortschritt Gefunden 2"
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, color, created_at) VALUES (?, '#123456', '2026-11-05')", (name,)).lastrowid
    lines = []
    monkeypatch.setattr(progress, "report", lines.append)
    monkeypatch.setattr(planner, "_materials_for_test", lambda conn, subject, **kw: [{"id": "x", "name": "vl.pdf", "text": "x", "content_sha256": "h-gleich"}])
    monkeypatch.setattr(ai, "generate_test", lambda *a, **kw: valid_test())
    try:
        planner.create_test(name, 15, module_id=mid, week_no=1, auto=False, log=lambda *_: None)
        planner.create_test(name, 15, module_id=mid, week_no=1, auto=False, log=lambda *_: None)
    finally:
        with db.cursor() as conn:
            conn.execute("DELETE FROM tests WHERE module_id=?", (mid,))
            conn.execute("DELETE FROM modules WHERE id=?", (mid,))
    assert lines[0] == "Gemeinsamer Test wird gesucht …" and "Aufgaben werden erstellt … 15 Aufgaben" in lines
    assert lines[-1] == "Gemeinsamer Test gefunden – wird übernommen …"
