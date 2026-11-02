"""Absagen aus Ankuendigungen am Termin im Planer (Wunsch des Inhabers 02.11.2026): Erkennung deutscher Formulierungen,
Zuordnung zu Kurs/Modul, Tag, Uhrzeit und Art, Hinweis statt stiller Loeschung, Entscheidung ueber event_exceptions."""
import json
from datetime import date

import pytest

POSTED = date(2026, 11, 2)                # Montag; 12.11.2026 ist ein Donnerstag


# ---------------------------------------------------------------- Erkennung

@pytest.mark.parametrize("text", [
    "Die Vorlesung am 12.11. fällt aus.",
    "Die Vorlesung fällt am 12.11. aus.",
    "Die Vorlesung fällt am Donnerstag, 12.11. leider aus.",
    "Die Übung am Donnerstag, 12.11., entfällt.",
    "Am 12.11. entfällt das Tutorium.",
    "Die Vorlesung findet am 12.11. nicht statt.",
    "Die Sitzung findet am Do., 12.11. nicht statt.",
    "Am 12.11. findet keine Vorlesung statt.",
    "Keine Vorlesung am 12.11.!",
    "Keine Vorlesungen am 12. November.",
    "Kein Tutorium am 12.11.",
    "Liebe Studierende,\nam Donnerstag, den 12.11. muss die Übung leider ausfallen.",
    "Die Sitzung am 12.11.2026 wird abgesagt.",
    "Die Vorlesung am 12.11.26 fällt aus.",
    "Ausfall der Vorlesung am 12. Nov.",
])
def test_cancellation_phrasings(text):
    from app.announcements import extract_dates
    assert [(d["date"], d["kind"]) for d in extract_dates(text, POSTED)] == [("2026-11-12", "ausfall")]


@pytest.mark.parametrize("text, kind", [
    ("Keine Übungsblätter am 12.11.", "termin"),                       # Blaetter sind keine Uebung
    ("Die Vorlesung am 12.11. findet statt.", "termin"),
    ("Die Vorlesung am 12.11. wird verschoben.", "verlegt"),
])
def test_not_a_cancellation(text, kind):
    from app.announcements import extract_dates
    assert extract_dates(text, POSTED)[0]["kind"] == kind


def test_subject_names_the_cancellation_when_only_one_day():
    from app.announcements import make
    a = make("sp-news-1", "studip", "c", "Vorlesung entfällt", "<p>Liebe Studierende, am 12.11. bin ich auf einer Tagung.</p>", "",
             "2026-11-02T09:00:00+01:00", None)
    assert [(d["date"], d["kind"]) for d in a["dates"]] == [("2026-11-12", "ausfall")]
    # mehrere Tage: offen, welcher gemeint ist
    b = make("sp-news-2", "studip", "c", "Vorlesung entfällt", "<p>Am 12.11. bin ich weg, ab 19.11. wieder da.</p>", "",
             "2026-11-02T09:00:00+01:00", None)
    assert [d["kind"] for d in b["dates"]] == ["termin", "termin"]


@pytest.mark.parametrize("snippet, title, want", [
    ("Die Vorlesung am 12.11. fällt aus, die Übung findet statt.", "", {"vorlesung"}),
    ("Die Übung am Donnerstag, 12.11., entfällt.", "", {"uebung", "hoersaaluebung", "gruppenuebung", "tutorium"}),
    ("Keine Vorlesung und keine Übung am 12.11.", "", {"vorlesung", "uebung", "hoersaaluebung", "gruppenuebung", "tutorium"}),
    ("Am 12.11. bin ich auf einer Tagung.", "Seminar fällt aus", {"seminar"}),
    ("Die Sitzung am 12.11. fällt aus.", "Hinweis", set()),
])
def test_cancel_targets(snippet, title, want):
    from app.announcements import cancel_targets
    assert cancel_targets(snippet, title) == want


# ---------------------------------------------------------------- Zuordnung im Planer

@pytest.fixture
def plan(app):
    """Modul mit Vorlesungskurs (Stud.IP) und Learnweb-Kurs; Vorlesung Do 10:15, Uebung Do 14:15, Tutorium Do 16:00,
    fremdes Modul Do 10:15."""
    from app import db
    db.init_db()
    with db.cursor() as conn:
        conn.execute("DELETE FROM announcements")
        saved_terms = db.rows(conn, "SELECT * FROM terms")
        conn.execute("DELETE FROM terms")
        conn.execute("INSERT INTO terms(name, start, end, active) VALUES ('WiSe 2026/27', '2026-10-12', '2027-01-30', 1)")
        m1 = conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Ausfallmathe', '#111111', 90, 't')").lastrowid
        m2 = conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Ausfallphysik', '#222222', 91, 't')").lastrowid
        for cid, title, kind, mid in (("ax-vl", "Ausfallmathe", "vorlesung", m1), ("ax-ue", "Übung Ausfallmathe", "uebung", m1),
                                      ("lw-ax", "Ausfallmathe (Learnweb)", "sonstiges", m1), ("ax-ph", "Ausfallphysik", "vorlesung", m2)):
            conn.execute("INSERT INTO courses(id, title, kind, active, module_id, created_at) VALUES (?,?,?,1,?,'t')", (cid, title, kind, mid))
        ids = {}
        for key, cid, mid, kind, st, en in (("vl", "ax-vl", m1, "vorlesung", "10:15", "11:45"), ("ue", "ax-ue", m1, "uebung", "14:15", "15:45"),
                                            ("tut", "ax-ue", m1, "tutorium", "16:00", "17:00"), ("ph", "ax-ph", m2, "vorlesung", "10:15", "11:45")):
            ids[key] = conn.execute("""INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, rrule, attend, source, created_at)
                                       VALUES (?,?,?,?,3,?,?,'weekly',1,'manual','t')""", (mid, cid, f"T-{key}", kind, st, en)).lastrowid
    yield ids
    with db.cursor() as conn:
        conn.execute("DELETE FROM announcements")
        conn.execute(f"DELETE FROM event_exceptions WHERE event_id IN ({','.join(str(i) for i in ids.values())})")
        conn.execute(f"DELETE FROM course_events WHERE id IN ({','.join(str(i) for i in ids.values())})")
        conn.execute("DELETE FROM courses WHERE id IN ('ax-vl','ax-ue','lw-ax','ax-ph')")
        conn.execute("DELETE FROM modules WHERE name IN ('Ausfallmathe','Ausfallphysik')")
        conn.execute("DELETE FROM terms")
        for t in saved_terms:
            conn.execute("INSERT INTO terms(name, start, end, active) VALUES (?,?,?,?)", (t["name"], t["start"], t["end"], t["active"]))


def _store(conn, i, course, title, text, posted="2026-11-02T09:00:00+01:00"):
    from app import announcements as ann
    a = ann.make(f"sp-news-ax{i}", "studip", course, title, f"<p>{text}</p>", "", posted, f"https://studip.example/n{i}")
    ann.store(conn, [a], "studip", "t")


def _hints(conn, day="2026-11-12"):
    from app import timetable
    d = date.fromisoformat(day)
    return {o["event_id"]: o for o in timetable.occurrences(conn, d, d) if o.get("event_id")}


def test_lecture_cancellation_marks_only_the_lecture(plan):
    from app import db
    with db.cursor() as conn:
        _store(conn, 1, "ax-vl", "Hinweis", "Die Vorlesung am 12.11. fällt aus, die Übung findet statt.")
        occ = _hints(conn)
        h = occ[plan["vl"]]["cancel_hint"]
        assert (h["label"], h["confirmed"], h["announcement_id"], h["source"]) == ("Ausfall?", False, "sp-news-ax1", "studip")
        assert h["snippet"] == "Die Vorlesung am 12.11. fällt aus, die Übung findet statt." and h["course_title"] == "Ausfallmathe"
        assert occ[plan["vl"]]["status"] == "teilnahme"                       # Hinweis, keine stille Loeschung
        assert "cancel_hint" not in occ[plan["ue"]] and "cancel_hint" not in occ[plan["ph"]]
        assert "cancel_hint" not in _hints(conn, "2026-11-19")[plan["vl"]]     # andere Woche


def test_learnweb_announcement_reaches_series_over_module(plan):
    from app import db
    with db.cursor() as conn:
        _store(conn, 2, "lw-ax", "Übung entfällt", "Liebe Studierende, am Donnerstag, den 12.11. bin ich verhindert.")
        occ = _hints(conn)
        assert occ[plan["ue"]]["cancel_hint"]["title"] == "Übung entfällt"
        assert occ[plan["tut"]]["cancel_hint"]["announcement_id"] == "sp-news-ax2"  # Tutorium zaehlt zur Uebung
        assert "cancel_hint" not in occ[plan["vl"]] and "cancel_hint" not in occ[plan["ph"]]


def test_without_kind_same_course_first_and_time_narrows(plan):
    from app import db
    with db.cursor() as conn:
        _store(conn, 3, "ax-ue", "Hinweis", "Die Sitzung am 12.11. fällt aus.")
        occ = _hints(conn)
        assert {e for e, o in occ.items() if "cancel_hint" in o} == {plan["ue"], plan["tut"]}   # Kurs ax-ue, nicht die Vorlesung
        _store(conn, 4, "ax-ue", "Hinweis", "Die Sitzung am 12.11. um 16 Uhr fällt aus.", posted="2026-11-03T09:00:00+01:00")
        conn.execute("DELETE FROM announcements WHERE id='sp-news-ax3'")
        occ = _hints(conn)
        assert {e for e, o in occ.items() if "cancel_hint" in o} == {plan["tut"]}
        _store(conn, 5, "ax-vl", "Hinweis", "Keine Vorlesung am 12.11. um 10 Uhr.")             # 10 Uhr fuer 10:15 (c. t.)
        assert "cancel_hint" in _hints(conn)[plan["vl"]]


def test_user_confirms_or_dismisses_with_existing_exceptions(plan):
    from app import db, timetable
    with db.cursor() as conn:
        _store(conn, 6, "ax-vl", "Hinweis", "Keine Vorlesung am 12.11.")
        s = db.get_settings(conn)
        busy = [b["title"] for b in timetable.busy_blocks(conn, date(2026, 11, 12), s, False)]
        assert "T-vl" in busy                                                    # unbestaetigt: Zeit bleibt belegt
        timetable.set_attendance(conn, plan["vl"], "2026-11-12", "cancelled")   # bestaetigt
        o = _hints(conn)[plan["vl"]]
        assert o["status"] == "ausfall" and (o["cancel_hint"]["label"], o["cancel_hint"]["confirmed"]) == ("fällt aus", True)
        assert "T-vl" not in [b["title"] for b in timetable.busy_blocks(conn, date(2026, 11, 12), s, False)]   # Zeit frei fuer den Lernplan
        timetable.set_attendance(conn, plan["vl"], "2026-11-12", "today_attend")  # verworfen: findet statt
        o = _hints(conn)[plan["vl"]]
        assert o["status"] == "teilnahme" and "cancel_hint" not in o
        timetable.set_attendance(conn, plan["vl"], "2026-11-12", "reset")       # zurueck: wieder Hinweis
        assert _hints(conn)[plan["vl"]]["cancel_hint"]["label"] == "Ausfall?"


def test_week_and_calendar_api_carry_the_hint(app, plan):
    from conftest import asgi_call
    from app import db
    with db.cursor() as conn:
        _store(conn, 7, "ax-vl", "Ausfall", "Die Vorlesung am 12.11. entfällt.")
    status, _, body = asgi_call(app, "GET", "/api/timetable/week?start=2026-11-09")
    day = {d["date"]: d for d in json.loads(body)["days"]}["2026-11-12"]
    ev = {e["event_id"]: e for e in day["events"]}
    assert status == 200 and ev[plan["vl"]]["cancel_hint"]["url"] == "https://studip.example/n7"
    assert day["notices"][0]["kind_label"] == "Ausfall?"
    status, _, body = asgi_call(app, "GET", "/api/calendar?start=2026-11-12&end=2026-11-12")
    ev = {e["event_id"]: e for e in json.loads(body)["days"][0]["events"]}
    assert status == 200 and ev[plan["vl"]]["cancel_hint"]["label"] == "Ausfall?"


def test_web_marks_cancelled_events():
    from pathlib import Path
    st = Path(__file__).resolve().parents[1] / "app" / "static"
    core, tt, plan, home, css = ((st / f).read_text(encoding="utf-8") for f in ("core.js", "views-tt.js", "views-plan.js", "views-home.js", "style.css"))
    assert 'e.cancel_hint ? "Ausfall?"' in core and '"fällt aus"' in core and 'icon("alert", 11)' in core
    assert tt.count("cancelMark(e)") == 1 and "${cancelBox(occ)}" in tt and 'data-att="cancelled"' in tt and 'data-att="today_attend"' in tt
    assert plan.count("cancelMark(e") == 2 and "cx-unsure" in plan and "el.dataset.cx" in plan
    assert "cancelMark(e)" in home
    assert ".cx-mark" in css and "var(--warn)" in css.split(".cx-mark", 1)[1][:800]


def test_compound_cancellation_and_old_stored_dates():
    """iPad 2.11.2026: "Keine Hörsaalübung am 02.11." galt als Raum-Hinweis (Hörsaal) und war gespeichert; zusammengesetzte
    Veranstaltungen sind ein Ausfall, und beim Markieren gelten die Regeln von jetzt, nicht der gespeicherte Stand."""
    from datetime import date
    from app.announcements import dates_for
    d = dates_for("Keine Hörsaalübung am 02.11.", "Liebe Studierende, am 02.11. findet keine Hörsaalübungstatt.", date(2026, 10, 26))
    assert d[0]["date"] == "2026-11-02" and d[0]["kind"] == "ausfall"
    assert dates_for("Info", "keine Gruppenübungen am 3.11.", date(2026, 10, 26))[0]["kind"] == "ausfall"
    assert dates_for("Info", "Es gibt keine Übungsblätter am 03.11.", date(2026, 10, 26))[0]["kind"] != "ausfall"
