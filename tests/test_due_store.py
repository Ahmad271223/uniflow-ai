"""Erkannte Fristen in der Datenbank (app/due_store.py) und Endpunkte /api/due (app/due_api.py), 05.11.2026: Seitentexte,
Dateinamen, Ankuendigungen; nicht doppelt neben Learnweb-Fristen und Klausurterminen; "Stimmt nicht", Bestaetigen,
eigene Uhrzeit; Kalender, Uebersicht und Klausurliste sehen sie. Nur erfundene Daten."""
import json
from datetime import date

import pytest

from conftest import asgi_call

TODAY = date(2026, 11, 4)


@pytest.fixture
def seeded(app, monkeypatch, tmp_path):
    from app import config, db, scriptsearch, study
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "fristen.db")
    monkeypatch.setattr(config, "UNIVERSITY", "luh")
    monkeypatch.setattr(study, "today", lambda: TODAY)
    db.init_db()
    with db.cursor() as conn:
        conn.execute("INSERT INTO modules(id, name, color, exam_date) VALUES (1, 'Lineare Algebra', '#175ee8', '2027-02-12')")
        conn.execute("INSERT INTO courses(id, title, active, module_id) VALUES ('c-la', 'Lineare Algebra I', 1, 1)")
        conn.execute("INSERT INTO courses(id, title, active, module_id) VALUES ('c-alt', 'Altes Fach', 0, NULL)")
        chdate = 1793000000          # Oktober 2026
        for fid, cid, name in [("f-b3", "c-la", "Blatt03.pdf"), ("f-ls", "c-la", "Loesung_Blatt02.pdf"), ("f-old", "c-alt", "Blatt09.pdf"),
                               ("f-nm", "c-la", "Uebung_04_Abgabe_2026-12-12.pdf")]:
            conn.execute("INSERT INTO files(id, course_id, name, chdate) VALUES (?,?,?,?)", (fid, cid, name, chdate))
        scriptsearch.store_pages(conn, "f-b3", ["Übungsblatt 3\nLineare Algebra I\nAbgabe: bis Mo, 07.12.2026, 12:00 Uhr im Kasten",
                                                "Die Klausur findet am 12.02.2027 statt."], chdate)
        scriptsearch.store_pages(conn, "f-ls", ["Lösung zu Blatt 2. Abgabe war am 20.11. Klausur am 19.02.2027."], chdate)
        scriptsearch.store_pages(conn, "f-old", ["Abgabe bis 10.12.2026"], chdate)
        conn.execute("""INSERT INTO announcements(id, source, course_id, title, text, posted_at) VALUES
                        ('sp-news-1', 'studip', 'c-la', 'Kurztestat', 'Das Kurztestat 1 findet am 14.12.2026 in der Übung statt.', '2026-11-01T10:00:00')""")
        conn.execute("""INSERT INTO deadlines(id, source, course_id, title, kind, due_at) VALUES
                        ('lw-ev-1', 'learnweb', 'c-la', 'Aufgabe 4 hochladen', 'abgabe', '2026-12-12T23:59')""")
    return app


def test_list_detects_and_merges(seeded):
    from app import db, due_store
    with db.cursor() as conn:
        r = due_store.list_due(conn, now="2026-11-04T09:00")
    got = [(x["date"], x["time"], x["kind"], x["title"], x["source"]) for x in r["items"]]
    assert got == [
        ("2026-12-07", "12:00", "abgabe", "Abgabe Blatt 3", "dokument"),
        ("2026-12-12", "23:59", "abgabe", "Aufgabe 4 hochladen", "learnweb"),
        ("2026-12-14", None, "test", "Kurztestat 1", "dokument"),
        ("2027-02-12", None, "klausur", "Klausur Lineare Algebra", "modul"),
    ], "Loesung, inaktiver Kurs, Dateiname am Tag der Learnweb-Frist und Klausur am Modultermin fehlen"
    first = r["items"][0]
    assert first["origin"] == "erkannt in Blatt03.pdf, S. 1" and first["file_id"] == "f-b3" and first["page"] == 1
    assert first["id"].startswith("due-") and len(first["id"]) == 20 and first["in_days"] == "in 33 Tagen"
    assert r["items"][2]["origin"] == "erkannt in der Ankündigung „Kurztestat“" and r["items"][2]["announcement_ids"] == ["sp-news-1"]
    assert r["refreshed"] is True and r["hidden"] == 0
    with db.cursor() as conn:
        again = due_store.list_due(conn, now="2026-11-04T09:00")
    assert again["refreshed"] is False and again["items"] == r["items"], "ohne neue Eingaben nichts neu"


def test_same_id_as_ipad():
    from app import due_store
    # Kennung = "due-" + 16 Hex aus SHA-256 von Bereich|Tag|Art (DueStore.groupID)
    assert due_store.group_id("m1", "2026-12-07", "abgabe") == "due-" + __import__("hashlib").sha256(b"m1|2026-12-07|abgabe").hexdigest()[:16]


def test_endpoints_hide_confirm_time(seeded):
    st, _, body = asgi_call(seeded, "GET", "/api/due")
    assert st == 200
    items = json.loads(body)["items"]
    blatt = next(x for x in items if x["title"] == "Abgabe Blatt 3")
    st, _, body = asgi_call(seeded, "PATCH", f"/api/due/{blatt['id']}", body=json.dumps({"time": "10:00", "confirmed": True}))
    assert st == 200 and json.loads(body)["time"] == "10:00" and json.loads(body)["confirmed"] is True and json.loads(body)["user_time"] is True
    assert asgi_call(seeded, "PATCH", f"/api/due/{blatt['id']}", body=json.dumps({"time": "25:00"}))[0] == 422
    assert asgi_call(seeded, "PATCH", "/api/due/due-0000000000000000", body=json.dumps({"hidden": True}))[0] == 404
    st, _, _ = asgi_call(seeded, "PATCH", f"/api/due/{blatt['id']}", body=json.dumps({"hidden": True}))
    assert st == 200
    r = json.loads(asgi_call(seeded, "GET", "/api/due")[2])
    assert r["hidden"] == 1 and all(x["id"] != blatt["id"] for x in r["items"])
    r = json.loads(asgi_call(seeded, "GET", "/api/due?hidden=1")[2])
    assert any(x["id"] == blatt["id"] and x["hidden"] for x in r["items"])
    # Entscheidung bleibt beim Neuberechnen
    st, _, body = asgi_call(seeded, "POST", "/api/due/refresh")
    assert st == 200 and set(json.loads(body)) == {"hits", "changed"}
    assert json.loads(asgi_call(seeded, "GET", "/api/due")[2])["hidden"] == 1
    st, _, body = asgi_call(seeded, "POST", "/api/due/backfill?limit=5")
    assert st == 200 and json.loads(body) == {"read": 0, "remaining": 0}


def test_calendar_dashboard_and_exams_see_detected(seeded):
    from app import db, holidays, exams, study
    with db.cursor() as conn:
        _, by_day = holidays.calendar_extras(conn, date(2026, 12, 1), date(2026, 12, 31))
        dl = study.upcoming_deadlines(conn, TODAY, limit=10)
        cands = exams.candidates(conn, TODAY)
    assert [(x["title"], x.get("detected", False)) for x in by_day["2026-12-07"]] == [("Abgabe Blatt 3", True)]
    assert [x["title"] for x in by_day["2026-12-12"]] == ["Aufgabe 4 hochladen"], "Dateiname am Tag der Learnweb-Frist: nicht doppelt"
    assert [x["title"] for x in dl] == ["Abgabe Blatt 3", "Aufgabe 4 hochladen", "Kurztestat 1"]
    assert dl[0]["deadline_id"].startswith("due-")
    det = [c for c in cands if c["kind"] == "erkannt"]
    assert [(c["date"], c["module_id"], c["label"]) for c in det] == [("2027-02-12", 1, "erkannt in Blatt03.pdf, S. 2")]
    with db.cursor() as conn:
        la = [x for x in exams.upcoming(conn, TODAY) if x["module_id"] == 1]
    assert len(la) == 1 and {s["kind"] for s in la[0]["sources"]} == {"modul", "erkannt"}, "ein Eintrag je Modul und Tag"


def test_other_semester_in_head_and_no_window(seeded):
    from app import db, due_store, scriptsearch
    with db.cursor() as conn:
        conn.execute("INSERT INTO files(id, course_id, name, chdate) VALUES ('f-ws20', 'c-la', 'Blatt05.pdf', 1793000000)")
        scriptsearch.store_pages(conn, "f-ws20", ["Übungsblatt 5 – Wintersemester 2020/21\nAbgabe bis 09.12."], 1793000000)
        items = due_store.list_due(conn, now="2026-11-04T09:00")["items"]
    assert all(x.get("file_id") != "f-ws20" for x in items)
    with db.cursor() as conn:
        assert due_store.list_due(conn, today=date(2035, 1, 1), now="2035-01-01T00:00")["items"] == []


def test_windows_notification_plugin_is_narrow():
    """Windows-App: Mitteilungen ueber tauri-plugin-notification, Rechte nur fuer die Seite des lokalen Backends; die
    Grund-Faehigkeit bleibt core:default (tests/test_desktop.py)."""
    from pathlib import Path
    src = Path(__file__).resolve().parents[1] / "apps" / "windows" / "src-tauri"
    cap = json.loads((src / "capabilities" / "notifications.json").read_text(encoding="utf-8"))
    assert cap["windows"] == ["main"] and cap["permissions"] == ["notification:default"]
    assert cap["remote"]["urls"] == ["http://127.0.0.1:*/*"]
    assert 'tauri-plugin-notification = "2"' in (src / "Cargo.toml").read_text(encoding="utf-8")
    assert ".plugin(tauri_plugin_notification::init())" in (src / "src" / "main.rs").read_text(encoding="utf-8")
