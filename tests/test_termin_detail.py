"""Termin-Detail (06.11.2026): was das Termin-Panel in Web und Windows (app/static/termin-detail.js) vom PC-Server braucht.
Vorkommen im Stundenplan mit Raum, Stud.IP-Kurs und Modul; Lehrende des Kurses (Dozent/innen vor Tutor/innen);
Raumfinder nur an der LUH (campuses.finder); aufgeloester Raum mit Route zu Fuss wie in den gemeinsamen Faellen
packages/shared-contracts/fixtures/termin-detail/cases.json (gleich in Swift und JS). Erfundene Personen, nie Netz."""
import json
from pathlib import Path
from urllib.parse import quote

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
CASES = json.loads((ROOT / "packages/shared-contracts/fixtures/termin-detail/cases.json").read_text(encoding="utf-8"))
ROOMS_FX = ROOT / "packages/shared-contracts/fixtures/rooms"


def _j(res):
    st, _, b = res
    return st, (json.loads(b) if b else None)


@pytest.fixture
def seeded(app, monkeypatch, tmp_path):
    from app import db, rooms, studip_lecturers as L
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "termin.db")
    rooms_cases = json.loads((ROOMS_FX / "cases.json").read_text(encoding="utf-8"))

    def search(term, page=0):
        name = rooms_cases["raw_map"].get(" ".join(term.split()).casefold(), "search-leer.json")
        return json.loads((ROOMS_FX / "raw" / name).read_text(encoding="utf-8"))

    def boom(*a, **k):
        raise AssertionError("Netz im Test")
    monkeypatch.setattr(rooms, "_post", boom)
    monkeypatch.setattr(rooms, "_fresh_token", boom)
    monkeypatch.setattr(rooms, "http_search", search)
    monkeypatch.setattr(rooms, "cache_path", lambda: tmp_path / "rooms-cache.json")
    db.init_db()
    with db.cursor() as conn:
        conn.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('university', 'luh')")
        conn.execute("INSERT INTO modules(id, name) VALUES (1, 'Mathematik für Ingenieure I')")
        conn.execute("INSERT INTO courses(id, title, active, module_id) VALUES ('c-ma', 'Mathematik für Ingenieure I', 1, 1)")
        L.store_course(conn, "c-ma", [
            {"user_id": "u-t", "role": "tutor", "position": 0, "label": "", "name": "Erfundener Tutor", "username": "etutor", "email": ""},
            {"user_id": "u-a", "role": "dozent", "position": 1, "label": "", "name": "Prof. Dr. Erika Beispiel", "username": "ebeispiel",
             "email": "erika.beispiel@example.org"},
            {"user_id": "u-b", "role": "dozent", "position": 2, "label": "", "name": "Dr. Max Muster", "username": "mmuster",
             "email": "max.muster@example.org"},
        ], "2026-11-05T09:00:00+01:00")
    return db


def test_occurrence_carries_room_course_and_module(app, seeded):
    st, ev = _j(asgi_call(app, "POST", "/api/timetable/events", body=json.dumps(
        {"title": "Mathematik für Ingenieure I", "kind": "vorlesung", "weekday": 3, "start_time": "10:00", "end_time": "11:30",
         "rrule": "weekly", "room": "1101 - F102", "module_id": 1, "course_id": "c-ma"})))
    assert st == 200, ev
    st, series = _j(asgi_call(app, "GET", "/api/timetable/events"))
    e = next(x for x in series if x["id"] == ev["id"])
    assert (e["room"], e["course_id"], e["module_id"]) == ("1101 - F102", "c-ma", 1), "das Panel liest Raum, Kurs und Modul der Serie"


def test_lecturers_of_the_course_lecturers_first(app, seeded):
    st, d = _j(asgi_call(app, "GET", "/api/lecturers?course_id=c-ma"))
    assert st == 200 and d["available"] is True and d["loaded"] is True
    assert [p["name"] for p in d["people"]] == ["Prof. Dr. Erika Beispiel", "Dr. Max Muster", "Erfundener Tutor"]
    assert [p["roles"] for p in d["people"]] == [["dozent"], ["dozent"], ["tutor"]]
    # "Allen Lehrenden schreiben" (termin-detail-logic.recipients): beide Dozent/innen, nicht der Tutor ohne Adresse
    assert [p["email"] for p in d["people"] if "dozent" in p["roles"]] == ["erika.beispiel@example.org", "max.muster@example.org"]
    st, d = _j(asgi_call(app, "GET", "/api/lecturers?course_id=" + quote("unbekannt", safe="")))
    assert d["people"] == [] and d["loaded"] is False and d["hint"]


def test_room_finder_only_at_luh_and_walking_route(app, seeded):
    assert _j(asgi_call(app, "GET", "/api/rooms/campuses?university=luh"))[1]["finder"] is True
    assert _j(asgi_call(app, "GET", "/api/rooms/campuses?university=hsh"))[1]["finder"] is False
    assert _j(asgi_call(app, "GET", "/api/rooms/campuses?university=hildesheim"))[1]["finder"] is False
    st, r = _j(asgi_call(app, "GET", "/api/rooms/resolve?text=" + quote("1101 - F102", safe="")))
    part = r["parts"][0]
    assert st == 200 and part["status"] == "found"
    want = CASES["route"][0]
    assert part["text"] == want["part"]["text"]
    for k in ("google_route", "google_app_route"):
        assert part["maps"][k] == want["part"]["maps"][k], "gemeinsamer Fall = Antwort des Servers"
    assert part["maps"]["google_route"].endswith("&travelmode=walking")
    assert part["maps"]["google_app_route"].endswith("&directionsmode=walking")


def test_cases_are_invented_and_consistent():
    for p in CASES["people"]:
        assert not p["email"] or p["email"].endswith("@example.org")
    ids = {p["id"] for p in CASES["people"]}
    assert set(CASES["groups"]["lecturers"]) | set(CASES["groups"]["tutors"]) == ids
