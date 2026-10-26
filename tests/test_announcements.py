"""Ankuendigungen der Lehrenden mit Terminen, Ferien-Ausfall undatierter Serien, LSF-Bemerkungen, ueberfaellige Fristen."""
import json
from datetime import date

import pytest


# ---------------------------------------------------------------- Termine in Texten

@pytest.mark.parametrize("text, posted, want", [
    ("Die Vorlesung am 12.11. fällt leider aus.", "2026-10-26", [("2026-11-12", None, "ausfall")]),
    ("Raumänderung: ab 4.11. in HC.N.0.08 (Hörsaal 4).", "2026-10-26", [("2026-11-04", None, "raum")]),
    ("Abgabe bis 15.1. um 23:59 Uhr", "2026-12-01", [("2027-01-15", "23:59", "frist")]),          # Jahreswechsel
    ("Sitzung am 12. Dezember 2026 findet online statt", "2026-10-26", [("2026-12-12", None, "online")]),
    ("Version 2.1.3, Tel. 05121.883, Seite 12.", "2026-10-26", []),
    ("Wie am 01.09. besprochen.", "2026-10-26", []),                                                  # Vergangenes
    ("Am 31.02. ist nichts.", "2026-10-26", []),                                                      # kein Datum
])
def test_extract_dates(text, posted, want):
    from app.announcements import extract_dates
    got = [(x["date"], x["time"], x["kind"]) for x in extract_dates(text, date.fromisoformat(posted))]
    assert got == want


def test_snippet_is_the_sentence_and_html_is_text():
    from app.announcements import extract_dates, html_to_text
    t = html_to_text("<p>Liebe Studierende,</p><p>die Sitzung am <b>3.11.</b> f&auml;llt aus.&nbsp;Danach normal.</p>")
    assert t == "Liebe Studierende,\ndie Sitzung am 3.11. fällt aus. Danach normal."
    (x,) = extract_dates(t, date(2026, 10, 26))
    assert x["snippet"] == "die Sitzung am 3.11. fällt aus."


# ---------------------------------------------------------------- Speicher, Anzeige, API

def _ann(i, course, text, posted="2026-10-27T09:00:00+01:00", source="learnweb", discussion=None):
    from app.announcements import make
    return make(f"{'lw-post' if source == 'learnweb' else 'sp-news'}-{i}", source, course, f"Hinweis {i}", f"<p>{text}</p>", "Dozentin",
                posted, f"https://lw.example/d{i}", discussion=discussion)


@pytest.fixture
def ann_db(app):
    from app import db
    db.init_db()
    with db.cursor() as conn:
        conn.execute("DELETE FROM announcements")
        conn.execute("INSERT OR REPLACE INTO courses(id, title, kind, active, created_at) VALUES ('lw-39', 'Soziale Arbeit', 'seminar', 1, '2026-10-26')")
    yield
    with db.cursor() as conn:
        conn.execute("DELETE FROM announcements")
        conn.execute("DELETE FROM courses WHERE id='lw-39'")


def test_store_upsert_and_removal_per_course(ann_db):
    from app import announcements as ann, db
    with db.cursor() as conn:
        r = ann.store(conn, [_ann(1, "lw-39", "Am 3.11. fällt die Sitzung aus."), _ann(2, "lw-39", "Willkommen")], "studip", "t1", course_ids=["lw-39"])
        assert r == {"new": 2, "total": 2, "removed": 0}
        r = ann.store(conn, [_ann(1, "lw-39", "Am 3.11. fällt die Sitzung aus. Ersatz am 10.11.")], "studip", "t2", course_ids=["lw-39"])
        assert r == {"new": 0, "total": 1, "removed": 1}                # Ankuendigung 2 in Stud.IP geloescht
        (row,) = db.rows(conn, "SELECT dates FROM announcements")
        assert [d["date"] for d in json.loads(row["dates"])] == ["2026-11-03", "2026-11-10"]


def test_calendar_dashboard_and_api_show_notices(app, ann_db, monkeypatch):
    from conftest import asgi_call
    from app import announcements as ann, db, study
    monkeypatch.setattr(study, "today", lambda: date(2026, 10, 28))
    with db.cursor() as conn:
        ann.store(conn, [_ann(1, "lw-39", "Die Sitzung am 3.11. fällt leider aus."),
                         _ann(2, "lw-39", "Alte Info vom Sommer", posted="2026-06-01T10:00:00+02:00")], "learnweb", "t")
    status, _, body = asgi_call(app, "GET", "/api/calendar?start=2026-11-02&end=2026-11-08")
    days = {d["date"]: d for d in json.loads(body)["days"]}
    (n,) = days["2026-11-03"]["notices"]
    assert status == 200 and (n["kind"], n["kind_label"], n["course_title"]) == ("ausfall", "Ausfall?", "Soziale Arbeit")
    assert n["snippet"] == "Die Sitzung am 3.11. fällt leider aus." and days["2026-11-04"]["notices"] == []
    status, _, body = asgi_call(app, "GET", "/api/timetable/week?start=2026-11-02")
    assert status == 200 and len({d["date"]: d for d in json.loads(body)["days"]}["2026-11-03"]["notices"]) == 1
    status, _, body = asgi_call(app, "GET", "/api/announcements")
    items = json.loads(body)["announcements"]
    assert status == 200 and [a["id"] for a in items] == ["lw-post-1"]           # Sommer-Info ohne kommenden Termin: zu alt
    assert items[0]["upcoming"][0]["date"] == "2026-11-03"
    status, _, body = asgi_call(app, "GET", "/api/dashboard")
    assert status == 200 and [a["id"] for a in json.loads(body)["announcements"]] == ["lw-post-1"]


def test_web_shows_notices():
    from pathlib import Path
    st = Path(__file__).resolve().parents[1] / "app" / "static"
    plan, tt, app_js, core = ((st / f).read_text(encoding="utf-8") for f in ("views-plan.js", "views-tt.js", "app.js", "core.js"))
    assert plan.count("noteChips(") >= 3 and "noteChips(d, true)" in tt and "Ankündigungen</h2>" in app_js
    assert "safeUrl(n.url)" in core and "esc(n.snippet)" in core


# ---------------------------------------------------------------- Abruf Learnweb (Seiten / REST) und Stud.IP

def test_sync_announcements_skips_known_and_removes_deleted(app, ann_db):
    from app import announcements as ann, db, hildesheim
    calls = []

    class Client:
        def announcements(self, courses, known):
            calls.append(set(known))
            items = [] if "lw-d-5838" in known else [ann.from_forum_post(
                {"id": 9101, "subject": "Raum", "author": "E", "posted_at": "2026-10-27T09:15:00+01:00", "html": "<p>Ab 10.11. in Raum 4.</p>"},
                "lw-39", "https://lw.example", 5838)]
            return items, {"lw-39": ["lw-d-5838"] if len(calls) < 3 else []}
    courses = [{"id": "lw-39", "moodle_id": 39, "semester": "", "hidden": False}]
    assert hildesheim.sync_announcements(Client(), courses).startswith("Ankuendigungen: 1 neu (1 mit Termin)")
    assert hildesheim.sync_announcements(Client(), courses).startswith("Ankuendigungen: 0 neu")
    assert calls[1] == {"lw-d-5838"}                                          # bekannte Diskussion nicht erneut geoeffnet
    assert hildesheim.sync_announcements(Client(), courses).endswith("1 entfernt")   # im Learnweb geloescht
    with db.cursor() as conn:
        assert db.rows(conn, "SELECT id FROM announcements") == []


def test_token_client_reads_news_forums_only():
    from app import learnweb
    seen = []

    def post(url, data):
        seen.append(data)
        if data["wsfunction"] == "mod_forum_get_forums_by_courses":
            return json.dumps([{"id": 5, "course": 39, "type": "news"}, {"id": 6, "course": 39, "type": "general"}]).encode()
        return json.dumps({"discussions": [{"id": 77, "discussion": 701, "subject": "Ausfall", "message": "<p>Am 3.11. fällt die Sitzung aus.</p>",
                                            "userfullname": "Dozentin", "created": 1793092500}]}).encode()
    items, seen_ids = learnweb.TokenClient("https://lw.example", "T", post=post).announcements([{"id": "lw-39", "moodle_id": 39}])
    assert [d["wsfunction"] for d in seen] == ["mod_forum_get_forums_by_courses", "mod_forum_get_forum_discussions"]
    assert seen[0]["courseids[0]"] == 39 and seen[1]["forumid"] == 5
    assert items[0]["id"] == "lw-post-77" and items[0]["dates"][0]["kind"] == "ausfall" and seen_ids == {"lw-39": ["lw-d-701"]}


def test_studip_news_form():
    from app.announcements import from_studip_news
    a = from_studip_news({"id": "abc", "attributes": {"title": "Raumwechsel", "content": "<p>Ab 4.11. im Hörsaal F 102.</p>",
                                                       "publication-start": "2026-10-20T00:00:00+02:00"}}, "c1", "https://studip.example")
    assert (a["id"], a["source"], a["dates"][0]["date"], a["dates"][0]["kind"]) == ("sp-news-abc", "studip", "2026-11-04", "raum")
    assert a["url"] == "https://studip.example/dispatch.php/course/overview?cid=c1"


# ---------------------------------------------------------------- Ferien: undatierte Serien fallen aus

@pytest.fixture
def series(app, monkeypatch):
    from app import config, db
    db.init_db()
    monkeypatch.setattr(config, "UNIVERSITY", "luh")
    with db.cursor() as conn:
        saved_terms = db.rows(conn, "SELECT * FROM terms")
        conn.execute("DELETE FROM terms")
        conn.execute("INSERT INTO terms(name, start, end, active) VALUES ('WiSe 2026/27', '2026-10-12', '2027-01-30', 1)")
        ids = {}
        for key, kind, df, dt in (("undatiert", "uebung", None, None), ("datiert", "vorlesung", "2026-10-13", "2027-01-26"),
                                  ("privat", "persoenlich", None, None)):
            cur = conn.execute("""INSERT INTO course_events(title, kind, weekday, start_time, end_time, rrule, date_from, date_to, attend, source, created_at)
                                  VALUES (?, ?, 1, '12:15', '13:45', 'weekly', ?, ?, 1, 'studip', '2026-10-26')""", (f"T-{key}", kind, df, dt))
            ids[key] = cur.lastrowid
    yield ids
    with db.cursor() as conn:
        conn.execute(f"DELETE FROM event_exceptions WHERE event_id IN ({','.join(str(i) for i in ids.values())})")
        conn.execute(f"DELETE FROM course_events WHERE id IN ({','.join(str(i) for i in ids.values())})")
        conn.execute("DELETE FROM terms")
        for t in saved_terms:
            conn.execute("INSERT INTO terms(name, start, end, active) VALUES (?,?,?,?)", (t["name"], t["start"], t["end"], t["active"]))


def test_undated_series_cancelled_on_breaks_only(series):
    from app import db, timetable
    with db.cursor() as conn:
        occ = {(o["event_id"], o["date"]): o for o in timetable.occurrences(conn, date(2026, 12, 15), date(2027, 1, 12))}
        u, dt, pv = series["undatiert"], series["datiert"], series["privat"]
        assert occ[(u, "2027-01-05")]["status"] == "ausfall" and occ[(u, "2027-01-05")]["note"] == "Weihnachtspause"
        assert occ[(u, "2026-12-29")]["status"] == "ausfall" and occ[(u, "2027-01-12")]["status"] == "teilnahme"
        assert occ[(dt, "2027-01-05")]["status"] == "teilnahme"     # Daten der Quelle: Stud.IP regelt Ausfaelle selbst
        assert occ[(pv, "2027-01-05")]["status"] == "teilnahme"     # persoenlich: nie
        timetable.set_exception(conn, u, "2027-01-05", "attend")       # Nutzer sagt: findet statt
        occ = {(o["event_id"], o["date"]): o for o in timetable.occurrences(conn, date(2027, 1, 5), date(2027, 1, 5))}
        assert occ[(u, "2027-01-05")]["status"] == "teilnahme"


# ---------------------------------------------------------------- LSF: Bemerkungen und Platzhalter

def test_lsf_notes_and_placeholder_once(app):
    from app import db, lsf
    db.init_db()
    base = {"title": "Studienbegleitseminar", "number": "0422", "lecturer": "", "kind": "seminar", "weekday": 0, "start_time": "07:00",
            "end_time": "07:15", "room": "", "rrule": "weekly", "date_from": "2026-10-19", "date_to": "2027-02-05", "exdates": []}
    ph = {**base, "note": lsf.note_text("<p><strong>Dieser Termin wird nur aus technischen Gr&uuml;nden angezeigt!</strong></p>")}
    ex = {**base, "title": "Kunst und Kultur", "number": "1528", "start_time": "10:00", "end_time": "12:00", "note": "Exkursion zur KuFa"}
    with db.cursor() as conn:
        conn.execute("DELETE FROM course_events WHERE source='lsf'")
        lsf.import_plan(conn, [dict(ph), dict(ex)])
        rows = {r["title"]: r for r in db.rows(conn, """SELECT e.title, n.note, e.attend FROM course_events e
                                                        LEFT JOIN event_notes n ON n.event_id=e.id WHERE e.source='lsf'""")}
        assert rows["Studienbegleitseminar"]["attend"] == 0 and "technischen" in rows["Studienbegleitseminar"]["note"]
        assert (rows["Kunst und Kultur"]["attend"], rows["Kunst und Kultur"]["note"]) == (1, "Exkursion zur KuFa")
        conn.execute("UPDATE course_events SET attend=1 WHERE source='lsf' AND title='Studienbegleitseminar'")   # Nutzer will hin
        assert lsf.import_plan(conn, [dict(ph), dict(ex)])["placeholders"] == 0
        assert db.row(conn, "SELECT attend FROM course_events WHERE source='lsf' AND title='Studienbegleitseminar'")["attend"] == 1
        conn.execute("DELETE FROM course_events WHERE source='lsf'")


# ---------------------------------------------------------------- ueberfaellige Fristen, Link

def test_overdue_deadlines_listed_first(app, monkeypatch):
    from app import db, hildesheim, study
    db.init_db()
    monkeypatch.setattr(study, "today", lambda: date(2026, 10, 26))
    items = [{"id": "lw-ev-o1", "course_id": None, "title": "Essay 1", "full_title": "Essay 1", "kind": "abgabe", "module": "assign",
              "due_at": "2026-10-01T23:59", "url": None, "overdue": True},
             {"id": "lw-ev-o2", "course_id": None, "title": "Test 2", "full_title": "Test 2", "kind": "test_beginn", "module": "quiz",
              "due_at": "2026-10-02T10:00", "url": None, "overdue": True},
             {"id": "lw-ev-o3", "course_id": None, "title": "Blatt 4", "full_title": "Blatt 4", "kind": "abgabe", "module": "assign",
              "due_at": "2026-11-04T23:59", "url": None, "overdue": False},
             {"id": "lw-ev-o4", "course_id": None, "title": "Alt", "full_title": "Alt", "kind": "abgabe", "module": "assign",
              "due_at": "2026-07-17T23:59", "url": None, "overdue": True}]                   # Vorsemester: nicht mehr zeigen
    with db.cursor() as conn:
        conn.execute("DELETE FROM deadlines")
        hildesheim.store_deadlines(conn, items, "t", "2026-06-28T00:00")
        up = study.upcoming_deadlines(conn, date(2026, 10, 26))
        assert [(u["title"], u["kind_label"], u["overdue"]) for u in up] == [("Essay 1", "überfällig: Abgabe", True), ("Blatt 4", "Abgabe", False)]
        dash = [u for u in study.dashboard(conn)["upcoming"] if u.get("deadline_id")]
        assert dash[0]["title"] == "Essay 1"
        conn.execute("DELETE FROM deadlines")


def test_lsf_current_lectures_link_is_the_working_variant():
    from app.universities import HILDESHEIM_SERVICES
    (s,) = [x for x in HILDESHEIM_SERVICES if x["key"] == "lsf-ausfall"]
    assert "type=0" in s["url"] and "type=1" not in s["url"] and "subitem=currentLectures" in s["url"]
