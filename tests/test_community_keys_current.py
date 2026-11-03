"""Community-Liste nur aktuelles Semester (03.11.2026, wie CommunitySpacesCard auf dem iPad): `/api/courses/community-keys`
liefert ohne Parameter weiter nur aktive Kurse (Fragen, Editor), mit `all=true` auch fruehere, je Kurs `active` und je
Modul `current` (mindestens eine Veranstaltung des Moduls ist aktiv)."""
import json

from conftest import asgi_call

COURSES = [("ck-a-vl", "Analysis A", 1), ("ck-a-ue", "Übung zu Analysis A", 0),   # Modul aktuell: ein Kurs aktiv reicht
           ("ck-old", "Alte Chemie", 0)]                                            # nur frueheres Semester


def _keys(app, q=""):
    st, _, raw = asgi_call(app, "GET", "/api/courses/community-keys" + q)
    assert st == 200, raw[:200]
    return {c["course_id"]: c for c in json.loads(raw)["courses"]}


def test_current_flag_and_older_courses(app):
    from app import db
    with db.cursor() as conn:
        for cid, title, active in COURSES:
            conn.execute("INSERT INTO courses(id, title, kind, active, created_at) VALUES (?,?, 'vorlesung', ?, 't')", (cid, title, active))
    try:
        default = _keys(app)
        assert "ck-a-vl" in default and "ck-a-ue" not in default and "ck-old" not in default
        assert default["ck-a-vl"]["active"] == 1 and default["ck-a-vl"]["current"] is True

        every = _keys(app, "?all=true")
        assert {"ck-a-vl", "ck-a-ue", "ck-old"} <= set(every)
        assert every["ck-a-vl"]["key"] == every["ck-a-ue"]["key"], "Uebung und Vorlesung teilen das Modul"
        assert every["ck-a-ue"]["active"] == 0 and every["ck-a-ue"]["current"] is True
        assert every["ck-old"]["active"] == 0 and every["ck-old"]["current"] is False
    finally:
        with db.cursor() as conn:
            conn.execute(f"DELETE FROM courses WHERE id IN ({','.join('?' * len(COURSES))})", [c[0] for c in COURSES])
