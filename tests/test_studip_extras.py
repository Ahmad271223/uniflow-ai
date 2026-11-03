"""Stud.IP-Ergaenzungen (02.11.2026): Semester und vorlesungsfreie Zeiten im Planer und Lernplan, Stud.IP-weite
Ankuendigungen, Nachrichten nur als Liste und nur lokal, Activity-Stream als Hinweis, Sprechstunden im Planer, fehlende
Endpunkte merken, Karte "Neuigkeiten" (/api/news). JSON:API-Antworten aus der gemeinsamen Fixture
packages/shared-contracts/fixtures/studip-extras/extras.json (tools/gen-studip-extras-fixture.py)."""
import json
import subprocess
import sys
from datetime import date
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
FX = json.loads((ROOT / "packages/shared-contracts/fixtures/studip-extras/extras.json").read_text(encoding="utf-8"))
TODAY = date(2026, 11, 2)


def test_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-studip-extras-fixture.py", "--check"], cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


# ---------------------------------------------------------------- reine Funktionen

def test_semesters_and_holidays_are_read_defensively():
    from app import studip_terms
    sems = studip_terms.parse_semesters(FX["semesters"]["response"]["data"])
    assert [s["id"] for s in sems] == ["kaputt", "s31", "s26", "s27"]                  # ohne Kennung fehlt
    ws = next(s for s in sems if s["id"] == "s26")
    assert (ws["lectures_start"], ws["lectures_end"]) == ("2026-10-12", "2027-02-06")
    assert next(s for s in sems if s["id"] == "kaputt")["start"] is None             # Unix-Zeit wird nicht geraten
    hols = studip_terms.parse_holidays(FX["holidays"]["response"]["data"])
    assert [(h["title"], h["start"], h["end"]) for h in hols] == [("Hochschultag", "2026-11-18", "2026-11-18"),
                                                                  ("Weihnachtspause", "2026-12-23", "2027-01-05")]


def test_studip_semesters_override_timetable_and_add_unknown():
    from app import studip_terms
    merged = studip_terms.merged_semesters("luh", {"semesters": FX["semesters"]["parsed"], "holidays": []})
    by = {n: (s, e, b) for n, s, e, b in merged}
    assert by["WiSe 2026/27"][:2] == ("2026-10-12", "2027-02-06")                     # Ende aus Stud.IP
    assert by["WiSe 2026/27"][2] == [("2026-12-23", "2027-01-05", "Weihnachtspause")]   # Unterbrechung bleibt
    assert by["SoSe 2027"][:2] == ("2027-04-12", "2027-07-24")
    assert by["WiSe 2031/32"] == ("2031-10-13", "2032-01-31", [])                        # unbekannt: dazu
    assert studip_terms.merged_semesters("luh", None)[1][2] == "2027-01-30"             # ohne Stud.IP wie bisher


def test_day_marks_with_studip():
    from app import holidays
    studip = {"semesters": FX["semesters"]["parsed"], "holidays": FX["holidays"]["parsed"]}
    hochschultag = holidays.day_marks(date(2026, 11, 18), date(2026, 11, 18), "luh", studip=studip)
    assert hochschultag == {"2026-11-18": [{"kind": "pause", "label": "Hochschultag"}]}
    assert holidays.day_marks(date(2026, 11, 18), date(2026, 11, 18), "luh") == {}
    # Weihnachtspause aus Zeitplan und Stud.IP mit gleichem Namen: einmal
    xmas = holidays.day_marks(date(2026, 12, 24), date(2026, 12, 24), "luh", studip=studip)
    assert xmas == {"2026-12-24": [{"kind": "pause", "label": "Weihnachtspause"}]}
    # Vorlesungen bis 06.02. laut Stud.IP: 02.02. ist kein vorlesungsfreier Tag mehr
    assert "2027-02-02" in holidays.day_marks(date(2027, 2, 2), date(2027, 2, 2), "luh")
    assert holidays.day_marks(date(2027, 2, 2), date(2027, 2, 2), "luh", studip=studip) == {}
    for m in FX["day_marks"]:
        lo, hi = date.fromisoformat(m["from"]), date.fromisoformat(m["to"])
        assert holidays.day_marks(lo, hi, "luh", studip=studip) == m["studip"]


def test_lecture_week_in_breaks():
    from app import studip_terms, study
    old = study.today
    study.today = lambda: TODAY
    try:
        studip = {"semesters": FX["semesters"]["parsed"], "holidays": FX["holidays"]["parsed"]}
        free = studip_terms.free_days(date(2026, 12, 21), date(2027, 2, 10), "luh", studip)
        got = {d["day"]: studip_terms.lecture_week(date(2026, 10, 12), date.fromisoformat(d["day"]), free) for d in FX["lecture_week"]["days"]}
    finally:
        study.today = old
    assert got["2026-12-28"] == got["2027-01-05"] == got["2026-12-21"] == 11       # Weihnachtspause: letzte Vorlesungswoche
    assert got["2027-01-11"] == 14                                                  # danach wie bisher
    assert got["2027-02-10"] == 17                                                  # nach Vorlesungsende (06.02.)


def test_missing_endpoints_are_remembered():
    from app import studip_extras as x
    for c in FX["should_ask"]:
        assert x.should_ask(c["missing"], c["name"], c["today"]) == c["ask"]
    for c in FX["remember"]:
        assert x.remember(c["missing"], c["name"], c["status"], "2026-11-02") == c["after"]


def test_messages_keep_only_list_fields_and_role():
    from app import studip_extras as x
    msgs = x.parse_messages(FX["messages"]["response"]["data"], FX["messages"]["response"]["included"], "https://studip.test", TODAY)
    assert msgs == FX["messages"]["items"]
    m1 = msgs[0]
    assert set(m1) == {"id", "sender", "subject", "preview", "sent_at", "url", "dates"}
    assert m1["sender"] == "Lehrende"                       # Rolle statt "Prof. Erika Test"
    assert m1["url"].endswith("/dispatch.php/messages/overview")   # Posteingang, nie die Einzelansicht
    assert [(d["date"], d["kind"]) for d in m1["dates"]] == [("2026-11-12", "ausfall"), ("2026-11-19", "frist")]
    assert all("snippet" not in d for d in m1["dates"])
    # ganzer Text (die Liste liefert `message` ganz), Absaetze bleiben, nie "…" (Inhaber 03.11.2026)
    long = msgs[2]["preview"]
    assert len(long) > 1000 and long.startswith("Hallo\nzusammen lange Nachricht") and long.endswith("Ende.")
    assert "…" not in long and msgs[2]["sender"] == "Absender"


def test_activity_skips_participants_and_news_and_names():
    from app import studip_extras as x
    act = x.parse_activity(FX["activity"]["response"]["data"], "https://studip.test")
    assert [a["id"] for a in act] == ["a1", "a2", "a3"]
    assert all(set(a) == {"id", "course_id", "type", "at", "url"} for a in act)


def test_bookings_with_iso_and_unix_times():
    from app import studip_extras as x
    with_tz = x.parse_bookings(FX["bookings"]["response"]["data"], FX["bookings"]["response"]["included"])
    assert with_tz[0] == {"id": "b1", "start": "2026-11-05T14:00:00", "end": "2026-11-05T14:15:00", "room": "Raum 101 (Testgebäude)"}
    assert [b["id"] for b in with_tz] == ["b1", "b2"]                 # b3 ohne lesbaren Slot fehlt


def test_feed_matches_fixture():
    from app import studip_extras as x
    f = FX["feed"]
    items = x.feed(f["news"], FX["messages"]["items"], f["activity"], "2026-11-02")
    assert items == f["items"]
    assert [i["kind"] for i in items[:3]] == ["ankuendigung", "nachricht", "aenderung"]
    assert items[1]["chips"] == [{"label": "Ausfall? 12.11.", "kind": "ausfall", "date": "2026-11-12"},
                                 {"label": "Frist 19.11.", "kind": "frist", "date": "2026-11-19"}]
    assert next(i for i in items if i["title"].startswith("Rückmeldung"))["who"] == "Stud.IP-weit"


# ---------------------------------------------------------------- Datenbank, Abgleich, Planer

@pytest.fixture
def clean(app):
    from app import db
    db.init_db()

    def wipe():
        with db.cursor() as conn:
            conn.execute("DELETE FROM announcements")
            conn.execute("DELETE FROM settings WHERE key='studip_missing_endpoints'")
            for t in ("studip_messages", "studip_activity", "studip_consultations", "studip_periods"):
                conn.execute(f"DROP TABLE IF EXISTS {t}")
            conn.execute("DELETE FROM courses WHERE id='k-vl'")
    wipe()
    yield
    wipe()


def _fake_get(answers, calls):
    def get(path):
        calls.append(path)
        for prefix, (status, body) in answers.items():
            if path.startswith(prefix):
                return status, body
        return 404, None
    return get


def test_sync_stores_and_remembers_missing_endpoints(clean):
    from app import db, studip_extras as x
    answers = {"semesters": (200, FX["semesters"]["response"]), "studip/news": (200, FX["global_news"]["response"]),
               "users/u1/inbox?page[limit]=30&include=sender": (200, FX["messages"]["response"]),
               "users/u1/activitystream": (200, FX["activity"]["response"]),
               "users/u1/consultation-bookings?include": (400, None),
               "users/u1/consultation-bookings": (200, {"data": FX["bookings"]["response"]["data"]})}
    calls: list[str] = []
    with db.cursor() as conn:
        conn.execute("INSERT INTO courses(id, title, kind, active, created_at) VALUES ('k-vl', 'Testmathematik', 'vorlesung', 1, 't')")
        res = x.sync(_fake_get(answers, calls), conn, "u1", "https://studip.test", TODAY, "2026-11-02T10:00:00")
        assert res["semesters"] == 4 and res["global_news"] == 2 and res["messages"] == 4 and res["activity"] == 3
        assert res["consultations"] == 0                               # ohne include keine Zeiten: nichts geraten
        assert "holidays" not in res and x.load_missing(conn) == {"holidays": "2026-11-02"}
        assert calls.count("users/u1/consultation-bookings") == 1      # nach 400 ohne include
        g = db.row(conn, "SELECT course_id, url FROM announcements WHERE id='sp-news-g1'")
        assert g["course_id"] is None and g["url"].endswith("/dispatch.php/start")
        # naechster Abgleich: holidays nicht erneut gefragt
        calls.clear()
        x.sync(_fake_get(answers, calls), conn, "u1", "https://studip.test", TODAY, "2026-11-02T11:00:00")
        assert not any(c.startswith("holidays") for c in calls)
        # Feed: Nachrichten, Aenderungen, Stud.IP-weit
        kinds = {i["kind"] for i in x.feed_for(conn, TODAY)}
        assert kinds == {"ankuendigung", "nachricht", "aenderung"}


def test_global_news_does_not_steal_course_news(clean):
    from app import announcements as ann, db, studip_extras as x
    with db.cursor() as conn:
        ann.store(conn, [ann.make("sp-news-k1", "studip", "k-vl", "Kurs", "x", "", "2026-10-30T08:00:00+01:00", None)], "studip", "t",
                  course_ids=["k-vl"])
        items = x.global_news(FX["global_news"]["response"]["data"], "https://studip.test")
        x.store_global_news(conn, items, "t")
        assert db.row(conn, "SELECT course_id FROM announcements WHERE id='sp-news-k1'")["course_id"] == "k-vl"
        x.store_global_news(conn, [], "t")                              # Stud.IP liefert keine mehr: global weg, Kurs bleibt
        assert [r["id"] for r in db.rows(conn, "SELECT id FROM announcements ORDER BY id")] == ["sp-news-k1"]


def test_messages_never_stored_in_hosted_service(clean, monkeypatch):
    from app import config, db, studip_extras as x
    monkeypatch.setattr(config, "is_hosted", lambda: True)
    calls: list[str] = []
    with db.cursor() as conn:
        x.sync(_fake_get({"users/u1/inbox": (200, FX["messages"]["response"])}, calls), conn, "u1", "https://studip.test", TODAY, "t")
        assert not any("inbox" in c for c in calls)
        assert x.store_messages(conn, FX["messages"]["items"], "t") == 0
        assert db.row(conn, "SELECT COUNT(*) n FROM studip_messages")["n"] == 0
        assert all(i["kind"] != "nachricht" for i in x.feed_for(conn, TODAY))


def test_consultations_and_studip_holidays_in_planner(clean):
    from app import db, studip_extras as x, studip_terms, timetable
    with db.cursor() as conn:
        x.store_consultations(conn, [{"id": "b1", "start": "2026-11-05T14:00:00", "end": "2026-11-05T14:15:00", "room": "Raum 101"}], "t")
        occ = timetable.occurrences(conn, date(2026, 11, 5), date(2026, 11, 5))
        c = [o for o in occ if o.get("source") == "studip-sprechstunde"]
        assert len(c) == 1 and (c[0]["start"], c[0]["end"], c[0]["title"], c[0]["event_id"]) == ("14:00", "14:15", "Sprechstunde", None)
        assert occ == sorted(occ, key=lambda o: (o["date"], o["start"] or ""))
        studip_terms.store(conn, "holiday", FX["holidays"]["parsed"], "t")
        assert studip_terms.load(conn)["holidays"][0]["title"] == "Hochschultag"
        from app import holidays
        marks, _ = holidays.calendar_extras(conn, date(2026, 11, 18), date(2026, 11, 18), "luh")
        assert marks == {"2026-11-18": [{"kind": "pause", "label": "Hochschultag"}]}


def test_api_news(app, clean):
    from conftest import asgi_call
    status, _, body = asgi_call(app, "GET", "/api/news")
    assert status == 200 and json.loads(body) == {"items": []}
