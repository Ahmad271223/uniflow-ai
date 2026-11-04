"""Blubber aus Stud.IP (app/studip_blubber.py, 03.11.2026), VORBEREITET und AUSGESCHALTET: Python-Fassung des Swift-Kerns
StudIPBlubber. Der Abgleich bleibt aus (SYNC_ENABLED = False, Entscheidung des Inhabers, Commit c740713: GET blubber-threads
raeumt in Stud.IP leere Threads auf, courses/{id}/blubber-threads legt Threads an). Geprueft wird deshalb vor allem, dass
nichts Stud.IP fragt; die Lese- und Speicherregeln laufen mit eingeschaltetem Schalter gegen erfundene Antworten."""
import json
from datetime import date
from pathlib import Path

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
BASE = "https://studip.test"
LIST = "jsonapi.php/v1/blubber-threads?page[limit]=40&include=author"
TODAY = date(2026, 11, 2)
NOW = "2026-11-02T12:00:00"


def comments_path(tid):
    return f"jsonapi.php/v1/blubber-threads/{tid}/comments?sort=-mkdate&page[limit]=20&include=author"


USERS = [
    {"type": "users", "id": "doz", "attributes": {"formatted-name": "Prof. Erika Mustermann", "family-name": "Mustermann", "permission": "dozent"}},
    {"type": "users", "id": "tut", "attributes": {"formatted-name": "Max Tutor", "family-name": "Tutor", "permission": "tutor"}},
    {"type": "users", "id": "stu", "attributes": {"formatted-name": "Lena Beispiel", "family-name": "Beispiel", "permission": "autor"}},
    {"type": "users", "id": "me", "attributes": {"formatted-name": "Ich Selbst", "permission": "autor"}},
]


def th(tid, ctx_type, course=None, content="", activity="2026-11-02T08:00:00+01:00", author=None, name="x"):
    rel = {"context": {"data": {"type": "courses", "id": course} if course else None}}
    if author:
        rel["author"] = {"data": {"type": "users", "id": author}}
    return {"type": "blubber-threads", "id": tid, "attributes": {"name": name, "context-type": ctx_type, "content": content, "content-html": "",
                                                                  "latest-activity": activity, "mkdate": "2026-10-20T10:00:00+02:00"}, "relationships": rel}


THREADS = {"data": [
    th("t-ana", "course", "c-ana", "", "2026-11-02T09:30:00+01:00", "doz", "Analysis I"),
    th("t-ana2", "course", "c-ana", 'Fragen zur Klausur hier sammeln, @"Lena Beispiel" schaut mit.', "2026-10-20T10:00:00+02:00", "tut"),
    th("global", "public", None, "", "2026-11-01T18:00:00+01:00", None, "Globaler Blubber"),
    th("t-priv", "private", None, "geheim", name="Lena Beispiel"),
    th("t-other", "course", "c-alt"),
    th("t-inst", "institute"),
    th("t-pub", "public", None, "Hallo Welt", author="stu", name="Blubber von Lena Beispiel"),
], "included": USERS}


def comment(cid, author, content, date_):
    c = {"type": "blubber-comments", "id": cid, "attributes": {"content": content, "content-html": "<p>x</p>", "mkdate": date_, "chdate": date_}, "relationships": {}}
    if author:
        c["relationships"]["author"] = {"data": {"type": "users", "id": author}}
    return c


def ana_comments():
    items = [comment("k1", "doz", "Die Übung am [Lena Beispiel]https://studip.test/dispatch.php/profile?username=lbeispiel fällt aus.", "2026-11-02T09:30:00+01:00"),
             comment("k2", "stu", "[quote=Max Tutor]alter Text[/quote] Danke! Gibt es eine Ersatzübung?", "2026-11-01T20:15:00+01:00"),
             comment("k3", "me", "Ich bringe Kekse mit @mmuster", "2026-11-01T19:00:00+01:00"),
             comment("k4", None, "Externer Gast fragt nach Skript", "2026-10-30T12:00:00+01:00"),
             comment("k5", "tut", "Siehe [Folien]https://example.org/folien.pdf und **wichtig**", "2026-10-20T08:00:00+02:00"),
             comment("k6", "stu", "   ", "2026-10-19T08:00:00+02:00")]
    items += [comment(f"k{i}", "stu", f"Alt {i} " + "lang " * 120, f"2026-10-0{min(9, max(1, 30 - i))}T08:00:00+02:00") for i in range(7, 26)]
    return {"data": items, "included": USERS}


def routes():
    return {LIST: THREADS, comments_path("t-ana"): ana_comments(),
            comments_path("t-ana2"): {"data": [comment("m1", "stu", "Wann ist die Klausur?", "2026-10-21T10:00:00+02:00")], "included": USERS},
            comments_path("global"): {"data": [comment("g1", "stu", "Mensa heute offen?", "2026-11-01T18:00:00+01:00")], "included": USERS}}


def getter(table, log):
    def get(path):
        log.append(path)
        r = table.get(path.lstrip("/"))
        return (404, None) if r is None else (200, r)
    return get


@pytest.fixture
def clean(app):
    from app import db
    db.init_db()

    def wipe():
        with db.cursor() as conn:
            conn.execute("DROP TABLE IF EXISTS studip_blubber")
            conn.execute("DELETE FROM settings WHERE key IN ('studip_blubber_activity', 'studip_blubber_fetched_at', 'studip_missing_endpoints')")
            conn.execute("DELETE FROM courses WHERE id='c-ana'")
            conn.execute("DELETE FROM modules WHERE name IN ('Analysis', 'Leer')")
    wipe()
    yield
    wipe()


@pytest.fixture
def on(monkeypatch):
    from app import studip_blubber
    monkeypatch.setattr(studip_blubber, "SYNC_ENABLED", True)


# ---------------------------------------------------------------- ausgeschaltet

def test_switched_off_asks_nothing():
    """Entscheidung des Inhabers: der Abgleich ist aus; ohne Schalter wird Stud.IP nie gefragt"""
    from app import studip_blubber as sb
    assert sb.SYNC_ENABLED is False
    log: list = []
    d = sb.fetch(getter(routes(), log), "me", ["c-ana"], {}, {}, "2026-11-02", BASE)
    assert log == [] and d.threads is None and d.requests == 0 and d.posts == {}


def test_nothing_in_the_sync_calls_blubber():
    """Weder der Abgleich noch ein Server-Pfad ruft den Abruf; die gefaehrlichen Routen kommen im Quelltext nicht vor"""
    for p in (ROOT / "app").glob("*.py"):
        text = p.read_text(encoding="utf-8")
        if p.name != "studip_blubber.py":
            assert "studip_blubber.fetch" not in text and "blubber_fetch" not in text, p.name
    code = (ROOT / "app" / "studip_blubber.py").read_text(encoding="utf-8")
    assert "courses/{" not in code.replace("courses/{id}/blubber-threads", ""), "keine Kurs-Route (legt Threads an)"
    for verb in ("post(", "patch(", "put(", "delete("):
        assert verb not in code.lower().replace("def ", ""), verb


# ---------------------------------------------------------------- Lesen

def test_threads_only_selected_courses_and_global_without_names():
    from app import studip_blubber as sb
    ts = sb.parse_threads(THREADS, {"c-ana"}, "me", BASE + "/")
    assert [t["id"] for t in ts] == ["t-ana", "t-ana2", "global"], "nur gewaehlter Kurs und der Stud.IP-weite Thread, nie privat/Einrichtung/fremd"
    assert ts[0]["course_id"] == "c-ana" and ts[2]["course_id"] is None
    assert ts[0]["opening"] is None, "Standard-Thread ohne eigenen Text"
    assert ts[0]["url"] == "https://studip.test/dispatch.php/course/messenger/course/t-ana?cid=c-ana"
    assert ts[2]["url"] == "https://studip.test/dispatch.php/blubber/index/global"
    o = ts[1]["opening"]
    assert o["author_role"] == "Tutor/in" and o["text"] == "Fragen zur Klausur hier sammeln, @Person schaut mit."
    assert o["posted_at"] == "2026-10-20T10:00:00" and ts[0]["latest_activity"] == "2026-11-02T09:30:00+01:00"


def test_comments_map_roles_and_strip_mentions():
    from app import studip_blubber as sb
    t = {"id": "t-ana", "course_id": "c-ana", "url": "u"}
    ps = sb.parse_comments(ana_comments(), t, "me")
    assert len(ps) == 20, "hoechstens 20, leere Beitraege fallen weg"
    assert [p["author_role"] for p in ps[:5]] == ["Lehrende", "Studierende", "du", "Teilnehmende", "Tutor/in"]
    assert ps[0]["text"] == "Die Übung am @Person fällt aus."
    assert ps[1]["text"] == "Danke! Gibt es eine Ersatzübung?"
    assert ps[2]["text"] == "Ich bringe Kekse mit @Person"
    assert ps[4]["text"] == "Siehe Folien und wichtig"
    assert ps[0]["posted_at"] == "2026-11-02T09:30:00" and ps[0]["id"] == "bc-k1"
    assert all(len(p["text"]) <= sb.MAX_TEXT + 2 for p in ps)
    for p in ps:
        for name in ("Mustermann", "Beispiel", "Tutor ", "Max", "Lena", "Erika", "lbeispiel", "mmuster", "Selbst"):
            assert name not in p["text"] and name not in p["author_role"], (name, p)


def test_long_posts_stay_whole():
    from app import studip_blubber as sb
    long = " ".join(f"Wort{i}" for i in range(1, 400))
    (p,) = sb.parse_comments({"data": [comment("z", "doz", long, "2026-11-02T09:30:00+01:00")], "included": USERS}, {"id": "t", "course_id": None, "url": "u"}, "me")
    assert p["text"] == long and "…" not in p["text"]


# ---------------------------------------------------------------- Abruf, Speicher, Endpunkte (Schalter eingeschaltet)

def test_fetch_store_endpoints_and_feed(app, clean, on):
    from app import db, studip_blubber as sb
    log: list = []
    d = sb.fetch(getter(routes(), log), "me", ["c-ana"], {}, {}, "2026-11-02", BASE)
    assert log == [LIST, comments_path("t-ana"), comments_path("t-ana2"), comments_path("global")], "eine Liste, dann je Thread die Kommentare"
    assert not any("/courses/" in p or "courses/" in p.split("blubber")[0] or "t-priv" in p or "t-pub" in p for p in log), "nie courses/{id}/blubber-threads"
    assert len(d.posts["t-ana"]) == 20 and len(d.posts["t-ana2"]) == 2, "Kommentar und Eroeffnung"
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, color) VALUES ('Analysis', '#ff0000')").lastrowid
        conn.execute("INSERT INTO courses(id, title, module_id, active, created_at) VALUES ('c-ana', 'Analysis I', ?, 1, 't')", (mid,))
        leer = conn.execute("INSERT INTO modules(name) VALUES ('Leer')").lastrowid
        assert sb.store(d, conn, NOW) == 23
        dump = json.dumps([dict(r) for r in conn.execute("SELECT * FROM studip_blubber")], ensure_ascii=False)
        for name in ("Mustermann", "Beispiel", "Lena", "Erika", "lbeispiel", "Selbst", "Max Tutor"):
            assert name not in dump, name
        assert conn.execute("SELECT COUNT(*) FROM studip_blubber WHERE course_id IS NULL").fetchone()[0] == 1
        by_module = sb.overview(conn, None, mid, TODAY)
        assert [t["id"] for t in by_module["threads"]] == ["t-ana", "t-ana2"], "neuester Beitrag zuerst, ohne Stud.IP-weit"
        ana = by_module["threads"][0]
        assert (ana["count"], ana["new_count"], ana["course_title"]) == (20, 3, "Analysis I"), "letzte 7 Tage, ohne eigene Beitraege: k1, k2, k4"
        assert ana["preview"] == "Lehrende: Die Übung am @Person fällt aus." and by_module["count"] == 22
        assert len(sb.overview(conn, "c-ana", None, TODAY)["threads"]) == 2
        allt = sb.overview(conn, None, None, TODAY)
        assert len(allt["threads"]) == 3 and allt["fetched_at"] == NOW
        assert sb.overview(conn, None, leer, TODAY)["threads"] == []
        t = sb.thread(conn, "t-ana2")
        assert [c["role"] for c in t["comments"]] == ["Tutor/in", "Studierende"]
        assert t["comments"][0]["text"] == "Fragen zur Klausur hier sammeln, @Person schaut mit."
        assert t["url"] == "https://studip.test/dispatch.php/course/messenger/course/t-ana2?cid=c-ana"
        assert sb.thread(conn, "nein") is None
        lines = sb.feed_lines(conn, TODAY)
        assert [x["title"] for x in lines] == ["Blubber in Analysis I: 3 neue Beiträge", "Blubber Stud.IP-weit: 1 neuer Beitrag"]
        assert lines[0]["at"] == "2026-11-02T09:30:00" and lines[0]["color"] == "#ff0000" and lines[0]["kind"] == "blubber"
        assert sb.feed_title("X", False, 1) == "Blubber in X: 1 neuer Beitrag"
        # zweiter Abruf: unveraenderte Threads werden nicht erneut gelesen; ein verschwundener Thread faellt weg
        kn = sb.known(conn)
        assert len(kn) == 3
        fewer = json.loads(json.dumps(THREADS).replace('"id": "t-ana2"', '"id": "t-weg"'))
        r2 = routes()
        r2[LIST] = fewer
        log2: list = []
        d2 = sb.fetch(getter(r2, log2), "me", ["c-ana"], {}, kn, "2026-11-02", BASE)
        assert log2 == [LIST, comments_path("t-weg")], "nur der neue Thread"
        sb.store(d2, conn, NOW)
        ids = [r[0] for r in conn.execute("SELECT DISTINCT thread_id FROM studip_blubber ORDER BY thread_id").fetchall()]
        assert ids == ["global", "t-ana"], "t-ana bleibt (unveraendert), t-ana2 weg, t-weg ohne Beitraege"


def test_news_feed_gets_the_blubber_lines(app, clean, on):
    from app import db, studip_blubber as sb, studip_extras, study
    with db.cursor() as conn:
        conn.execute("INSERT INTO courses(id, title, active, created_at) VALUES ('c-ana', 'Analysis I', 1, 't')")
        sb.store(sb.fetch(getter(routes(), []), "me", ["c-ana"], {}, {}, "2026-11-02", BASE), conn, NOW)
        items = studip_extras.feed_for(conn, TODAY)
        assert [i["kind"] for i in items if i["kind"] == "blubber"] == ["blubber", "blubber"]
    status, _, body = asgi_call(app, "GET", "/api/news")
    assert status == 200 and isinstance(json.loads(body)["items"], list)


def test_endpoints_without_data_are_empty(app, clean):
    status, _, body = asgi_call(app, "GET", "/api/studip/blubber")
    o = json.loads(body)
    assert status == 200 and o == {"threads": [], "count": 0, "fetched_at": None}
    status, _, body = asgi_call(app, "GET", "/api/studip/blubber?module=3&course=x")
    assert status == 200 and json.loads(body)["threads"] == []
    assert asgi_call(app, "GET", "/api/studip/blubber?module=x")[0] == 422
    status, _, body = asgi_call(app, "GET", "/api/studip/blubber/nein")
    assert status == 404 and json.loads(body)["detail"] == "Blubber nicht gefunden"


def test_endpoints_with_data(app, clean, on):
    from app import db, studip_blubber as sb
    with db.cursor() as conn:
        conn.execute("INSERT INTO courses(id, title, active, created_at) VALUES ('c-ana', 'Analysis I', 1, 't')")
        sb.store(sb.fetch(getter(routes(), []), "me", ["c-ana"], {}, {}, "2026-11-02", BASE), conn, NOW)
    o = json.loads(asgi_call(app, "GET", "/api/studip/blubber?course=c-ana")[2])
    assert len(o["threads"]) == 2 and o["threads"][0]["id"] == "t-ana"
    t = json.loads(asgi_call(app, "GET", "/api/studip/blubber/t-ana2")[2])
    assert [c["role"] for c in t["comments"]] == ["Tutor/in", "Studierende"]


def test_missing_endpoint_remembered_thirty_days_and_session_keeps_stock(clean, on):
    from app import db, studip_blubber as sb
    d = sb.fetch(getter({}, []), "me", ["c-ana"], {}, {}, "2026-11-02", BASE)
    assert d.threads is None and d.missing == {"blubber": "2026-11-02"}
    log: list = []
    soon = sb.fetch(getter(routes(), log), "me", ["c-ana"], d.missing, {}, "2026-11-20", BASE)
    assert log == [] and soon.threads is None, "innerhalb von 30 Tagen nicht gefragt"
    later = sb.fetch(getter(routes(), log), "me", ["c-ana"], d.missing, {}, "2026-12-02", BASE)
    assert later.threads is not None and "blubber" not in later.missing
    with db.cursor() as conn:
        conn.execute("INSERT INTO courses(id, title, active, created_at) VALUES ('c-ana', 'Analysis I', 1, 't')")
        sb.store(later, conn, NOW)
        n0 = conn.execute("SELECT COUNT(*) FROM studip_blubber").fetchone()[0]
        expired = sb.fetch(lambda p: (200, None), "me", ["c-ana"], {}, {}, "2026-11-02", BASE)       # HTML statt JSON
        assert expired.session_expired and expired.threads is None
        sb.store(expired, conn, NOW)
        assert conn.execute("SELECT COUNT(*) FROM studip_blubber").fetchone()[0] == n0


def test_request_budget(on):
    from app import studip_blubber as sb
    data = [th(f"t{i}", "course", f"c{i % 3}") for i in range(30)]
    log: list = []
    d = sb.fetch(getter({LIST: {"data": data}}, log), "me", ["c0", "c1", "c2"], {}, {}, "2026-11-02", BASE)
    assert len(d.threads) == 30 and len(log) == 1 + sb.MAX_THREADS and d.requests == 1 + sb.MAX_THREADS


def test_nothing_stored_in_the_hosted_service(clean, on, monkeypatch):
    from app import config, db, studip_blubber as sb
    monkeypatch.setattr(config, "is_hosted", lambda: True)
    with db.cursor() as conn:
        d = sb.fetch(getter(routes(), []), "me", ["c-ana"], {}, {}, "2026-11-02", BASE)
        assert sb.store(d, conn, NOW) == 0
        assert sb.overview(conn, None, None, TODAY)["threads"] == [] and sb.thread(conn, "t-ana") is None and sb.feed_lines(conn, TODAY) == []
