"""Kommende Klausuren aus allen Quellen (app/exams.py, 04.11.2026): Erkennung in Texten, Zusammenfuehren je Modul und
Tag, Quelle, Klausurtermin am Modul fuellen (nie ueberschreiben), Endpunkt GET /api/exams/upcoming, Chips mit
Pruefungen zuerst und die Art der Stud.IP-Termine. Nur erfundene Daten."""
import json
import subprocess
import sys
from datetime import date
from pathlib import Path

from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "packages" / "shared-contracts" / "fixtures" / "exams" / "exams.json"
P = date(2026, 11, 2)


def test_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-exams-fixture.py", "--check"], cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def _days(title, text):
    from app import exams
    return [(x["date"], x["time"], x["word"]) for x in exams.exam_dates(title, text, P)]


def test_exam_dates_clause_sentence_and_subject():
    assert _days("Klausurtermin", "Die Klausur findet am 12.02.2027 um 9 Uhr statt, die Anmeldung ist bis 01.02. möglich.") == \
        [("2027-02-12", "09:00", "Klausur")]
    assert _days("Info", "Klausur: Do., 11.02.2027, 10 Uhr, Raum E214. Einsicht am 20.02.") == [("2027-02-11", "10:00", "Klausur")]
    assert _days("Klausur", "Termin: 12.02.2027, 10:00, HS 1") == [("2027-02-12", None, "Klausur")]
    assert _days("Klausur", "Termine: 12.02.2027 und 19.02.2027.") == [], "Betreff allein bei mehreren Tagen: offen"
    assert _days("Nachklausur", "Nachklausur am 1. April 2027 um 14 Uhr") == [("2027-04-01", "14:00", "Nachklausur")]


def test_exam_dates_ignores_registration_review_mock_cancel_and_old_day():
    assert _days("Anmeldung", "Bitte meldet euch bis zum 15.01. zur Klausur an.") == []
    assert _days("Ergebnisse", "Die Klausurergebnisse und die Klausureinsicht am 01.03.2027.") == []
    assert _days("Probeklausur", "Die Probeklausur schreiben wir am 20.11.") == []
    assert _days("Ausfall", "Die Klausur am 12.02. entfällt.") == []
    assert _days("Verlegung", "Die Klausur wird vom 10.02. auf den 15.02.2027 verschoben.") == [("2027-02-15", None, "Klausur")]


def test_studip_category_is_read():
    from app import studip_sync
    e = studip_sync.event_from_studip({"id": "x", "attributes": {"start": "2027-02-12T09:00:00+01:00", "end": "2027-02-12T11:00:00+01:00",
                                                                  "categories": "Klausur"}}, "c1")
    assert e["category"] == "Klausur"
    assert studip_sync.event_from_studip({"id": "y", "attributes": {"categories": 3}}, "c1")["category"] == ""


def test_chips_put_exams_first_and_never_cut_them():
    from app import studip_extras
    dates = [{"date": "2026-11-10", "kind": "frist"}, {"date": "2026-11-11", "kind": "ausfall"}, {"date": "2026-11-12", "kind": "verlegt"},
             {"date": "2027-02-12", "kind": "pruefung"}, {"date": "2027-03-01", "kind": "pruefung"}]
    assert [c["label"] for c in studip_extras.chips(dates, "2026-11-04")] == \
        ["Prüfung 12.02.", "Prüfung 01.03.", "Frist 10.11.", "Ausfall? 11.11."]


def _seed(conn):
    fx = json.loads(FIXTURE.read_text(encoding="utf-8"))
    for s in fx["seed"]:
        conn.execute(s["sql"], s["params"])


def test_endpoint_merges_sources_and_fills_exam_date(app, monkeypatch, tmp_path):
    from app import db, study
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "klausuren.db")      # eigene Datenbank, die anderen Tests bleiben unberuehrt
    db.init_db()
    with db.cursor() as conn:
        _seed(conn)
    monkeypatch.setattr(study, "today", lambda: date(2026, 11, 4))
    st, _, body = asgi_call(app, "GET", "/api/exams/upcoming")
    assert st == 200
    r = json.loads(body)
    assert r["filled"] == 3 and r["today"] == "2026-11-04"
    ana = next(x for x in r["items"] if x["module_id"] == 1)
    assert (ana["date"], ana["time"], ana["room"]) == ("2027-02-12", "09:00", "Hörsaal F 303 · Hörsaal F 102")
    assert [s["kind"] for s in ana["sources"]] == ["studip", "ankuendigung"], "Stud.IP und Ankuendigung am selben Tag: ein Eintrag"
    assert ana["source_label"] == "aus Stud.IP-Terminen · aus Ankündigung vom 01.11.2026"
    la = next(x for x in r["items"] if x["module_id"] == 2)
    assert la["user_set"] and la["sources"][0]["label"] == "selbst eingetragen"
    with db.cursor() as conn:
        dates = {m["id"]: m["exam_date"] for m in db.rows(conn, "SELECT id, exam_date FROM modules")}
    assert dates == {1: "2027-02-12", 2: "2027-02-20", 3: "2027-02-05", 4: "2027-02-15", 5: None}, \
        "leer -> gefuellt, selbst eingetragen bleibt, vom Nutzer geleert bleibt leer"
    st, _, body = asgi_call(app, "GET", "/api/exams/upcoming?module_id=1")
    assert [x["date"] for x in json.loads(body)["items"]] == ["2027-02-12"]
    st, _, body = asgi_call(app, "PATCH", "/api/modules/4", body=json.dumps({"exam_date": "2027-02-16"}))
    assert st == 200
    asgi_call(app, "GET", "/api/exams/upcoming")
    with db.cursor() as conn:
        assert db.row(conn, "SELECT exam_date FROM modules WHERE id=4")["exam_date"] == "2027-02-16", "nie ueberschrieben"


def test_registered_exams_with_date_feed_upcoming(monkeypatch, tmp_path):
    """Uni Hildesheim (und LUH): gelesene Anmeldungen mit Termin ("Meine POS-Anmeldungen" im LSF bzw. "Info über
    angemeldete Prüfungen" im QIS) sind eine Quelle der Klausurtermine, mit Uhrzeit und Raum; stornierte nicht.
    Learnweb-Tests mit "Klausur" im Namen kommen als Frist dazu. Erfundene Zeilen."""
    from app import db, exams, qis_registrations
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "klausuren-lsf.db")
    db.init_db()
    with db.cursor() as conn:
        conn.execute("INSERT INTO modules(id, name, color, created_at) VALUES (7, 'Grundlagen der Informatik', '#4f5bd5', 't')")
        qis_registrations.store(conn, [
            {"pruefungsnr": "4711", "text": "Grundlagen der Informatik", "semester": "WiSe 26/27", "datum": "15.02.2027",
             "time": "10:00", "room": "Forum HS 1", "status": "zugelassen", "raw": ""},
            {"pruefungsnr": "5040", "text": "Statistik I", "semester": "WiSe 26/27", "datum": "22.02.2027", "time": "09:00",
             "status": "storniert", "raw": ""},
            {"pruefungsnr": "5032", "text": "Seminar ohne Termin", "semester": "WiSe 26/27", "status": "AN", "raw": ""},
        ], "t")
        conn.execute("""INSERT INTO deadlines(id, source, course_id, title, kind, due_at, url, fetched_at)
                        VALUES ('lw-ev-1', 'learnweb', NULL, 'E-Klausur Statistik', 'test_ende', '2027-02-10T12:00', 'https://x', 't')""")
        items = exams.upcoming(conn, date(2026, 11, 20))
    gi = next(x for x in items if x.get("module_id") == 7)
    assert (gi["date"], gi["time"], gi["room"]) == ("2027-02-15", "10:00", "Forum HS 1")
    assert [s["kind"] for s in gi["sources"]] == ["anmeldung"] and gi["source_label"] == "aus deinen angemeldeten Prüfungen"
    assert not any("Statistik I" == (x.get("title_name") or x.get("module_name") or "") for x in items)
    assert not any(x["date"] == "2027-02-22" for x in items), "storniert: kein Termin"
    lw = next(x for x in items if x["date"] == "2027-02-10")
    assert lw["sources"][0]["label"] == "aus dem Learnweb-Kalender"
