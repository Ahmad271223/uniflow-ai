"""Stundenplan nach dem eigenen Stud.IP-Kalender (users/{id}/events.ics), gleiche Regel wie StudIPCalendar im Swift-Kern.

Befund mit echten Daten (docs/STAND-MAC-SITZUNG.md, „Echte Daten vom iPad“, Punkt 1; Windows-App am 27.10.2026): die
eigene Programmier-Übung fehlte, weil der Kurs viele parallele Gruppen hat und die bisherige Regel alles zur Auswahl
stellte. Erfundene Antworten: packages/shared-contracts/fixtures/studip-schedule/kalender (dieselben wie im Swift-Test).
"""
import json
from pathlib import Path

import pytest

from conftest import asgi_call

KAL = Path(__file__).resolve().parents[1] / "packages" / "shared-contracts" / "fixtures" / "studip-schedule" / "kalender"
FETCHED = "2026-10-25T14:30:05"          # Uhr des Swift-Tests: Sonntag, 25.10.2026, 14:30

# Stundenplan mit Kalender wie im Swift-Test (withCalendar): eigene Gruppen, Kurszeit „Hauptveranst.“ neben vielen
# Gruppen, alle vier Fragestunden, eine Serie für zwei Räume zur selben Zeit, der eigene Eintrag. Python fasst
# Einzeltermine zu Serien; die ganz vergangene Kurszeit (zwei Termine Fr 12:00) bleibt wie bisher zwei Einzeltermine.
WITH_CALENDAR = [
    "Testvorlesung Kalender|0|10:00|Hörsaal K1|1",
    "Fragestunden Testmathe|0|14:00|Raum F1|1",
    "Übung Testvorlesung Kalender|1|08:00|Raum U1|1",
    "Fragestunden Testmathe|1|16:00|Raum F1|1",
    "Übung Testvorlesung Kalender|2|08:00|Raum U3|1",
    "Fragestunden Testmathe|2|16:00|Raum F1|1",
    "Lerngruppe Kalender alle 2 Wochen|2|18:00||1",
    "Tutorium Testphysik|3|08:00|Raum T1|1",
    "Fragestunden Testmathe|3|16:00|Raum F1|1",
    "Übung Testprogrammierung Kalender|4|09:40|Hörsaal K2|1",
    "Testvorlesung Kalender|4|12:00|Hörsaal K1|1",
    "Testvorlesung Kalender|4|12:00|Hörsaal K1|1",
]


def _load(name):
    return json.loads((KAL / name).read_text(encoding="utf-8"))


def _clean(conn):
    conn.execute("DELETE FROM event_exceptions WHERE event_id IN (SELECT id FROM course_events WHERE course_id LIKE 'k-%' OR title LIKE 'Lerngruppe Kalender%')")
    conn.execute("DELETE FROM course_events WHERE course_id LIKE 'k-%' OR title LIKE 'Lerngruppe Kalender%'")
    for t in ("studip_events", "studip_series_relevance"):
        conn.execute(f"DELETE FROM {t} WHERE course_id LIKE 'k-%'")
    conn.execute("DELETE FROM courses WHERE id LIKE 'k-%'")
    conn.execute("DELETE FROM studip_calendar_dates")
    conn.execute("DELETE FROM studip_schedule_entries WHERE id LIKE 'pe-k-%'")


def _seed(conn):
    """Wie run_studip_sync: Kurse, Einzeltermine (abgesagte fehlen wie in fetch_events), persönliche Einträge."""
    from app import studip_sync
    _clean(conn)
    for c in _load("users-courses.json")["data"]:
        studip_sync.upsert_course(conn, {"id": c["id"], "title": c["attributes"]["title"], "number": None, "semester": "WiSe 26/27"}, FETCHED)
        conn.execute("UPDATE courses SET active=1 WHERE id=?", (c["id"],))
    for f in sorted(KAL.glob("course-events-*.json")):
        course = f.stem.replace("course-events-", "")
        events = [{"id": e["id"], "course_id": course, "title": e["attributes"].get("title") or "",
                   "start": e["attributes"]["start"][:19], "end": e["attributes"]["end"][:19],
                   "room": (e["attributes"].get("location") or "").split(",")[0].strip()}
                  for e in _load(f.name)["data"] if e.get("id") and not e["attributes"].get("is-cancelled")]
        studip_sync.store_events(conn, events)
    personal = [{"id": d["id"], "title": d["attributes"]["title"], "weekday": int(d["attributes"]["weekday"]) - 1,
                 "start": d["attributes"]["start"], "end": d["attributes"]["end"], "description": d["attributes"].get("description") or ""}
                for d in _load("users-schedule.json")["data"] if d["type"] == "schedule-entries"]
    studip_sync.store_schedule_entries(conn, personal)


def _calendar(conn):
    from app import timetable
    ids = timetable.calendar_date_ids((KAL / "users-events.ics").read_text(encoding="utf-8"))
    assert timetable.store_calendar(conn, ids, FETCHED)
    return ids


def _series(conn):
    from app import db
    rows = db.rows(conn, """SELECT title, weekday, start_time, room, attend FROM course_events
                            WHERE course_id LIKE 'k-%' OR title LIKE 'Lerngruppe Kalender%' ORDER BY weekday, start_time, title""")
    return [f"{r['title']}|{r['weekday']}|{r['start_time']}|{r['room'] or ''}|{r['attend']}" for r in rows]


@pytest.fixture
def conn(app):
    from app import db
    with db.cursor() as c:
        try:
            yield c
        finally:
            _clean(c)


def test_calendar_date_ids_only_course_dates():
    from app import timetable
    ics = ("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:Stud.IP-0f0f@studip.test\r\nEND:VEVENT\r\n"
           "BEGIN:VEVENT\r\nUID:Stud.IP-SEM-ab\r\n c@studip.test\r\nEND:VEVENT\r\n"
           "BEGIN:VEVENT\r\nUID:Stud.IP-SEM-def@studip.test\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:Stud.IP-SEM-def@studip.test\r\nEND:VEVENT\r\n")
    assert timetable.calendar_date_ids(ics) == ["abc", "def"], "eigene Kalendertermine fehlen, gefaltete Zeilen, keine Doppelten"
    assert timetable.calendar_date_ids("") == [] and timetable.calendar_date_ids("<html>Anmelden</html>") == []
    ids = timetable.calendar_date_ids((KAL / "users-events.ics").read_text(encoding="utf-8"))
    assert len(ids) == 44, "wie im Swift-Test: Kurstermine ab der Abfrage samt Ausfall-Eintrag, ohne eigenen Termin"


def test_calendar_picks_own_groups(conn):
    """Die eigene Übungsgruppe, „Hauptveranst.“ neben vielen Gruppen und alle Fragestunden kommen; fremde Gruppen und
    der Kurs ohne Kalendertermine nicht. Zweiter Abgleich: nichts doppelt, nichts entfernt."""
    from app import timetable
    _seed(conn)
    _calendar(conn)
    r = timetable.auto_import(conn)
    assert _series(conn) == WITH_CALENDAR
    assert r["calendar"] is True and r["removed"] == 0
    pending = {e["title"]: e for e in timetable.studip_entries(conn) if not e.get("selected")}
    assert pending["Testmathe ohne Kalender"]["calendar"] == "kurs_fehlt", "bleibt in der Vorschau wählbar"
    assert "Stud.IP-Kalender" in pending["Testmathe ohne Kalender"]["hint"]
    again = timetable.auto_import(conn)
    assert again["new"] == 0 and again["removed"] == 0 and _series(conn) == WITH_CALENDAR


def test_without_calendar_the_old_rule_stays(conn):
    from app import timetable
    _seed(conn)
    r = timetable.auto_import(conn)
    s = _series(conn)
    assert r["calendar"] is False and r["pending_groups"] > 0, "Gruppen bleiben zur Auswahl"
    assert "Testmathe ohne Kalender|1|10:00|Hörsaal K3|1" in s, "ohne Kalender bisherige Regel"
    assert not any(x.startswith("Fragestunden") for x in s), "vier Serien gelten ohne Kalender als Gruppen"
    assert not any(x.startswith("Übung Testprogrammierung Kalender") for x in s), "der Fehler aus der Windows-App"


def test_calendar_removes_what_is_not_own_but_keeps_user_changes(conn):
    """Erst ohne Kalender übernommen, dann mit: was nicht im Kalender steht, verschwindet; eigene Änderungen bleiben."""
    from app import db, timetable
    _seed(conn)
    timetable.auto_import(conn)
    thu = db.row(conn, "SELECT id FROM course_events WHERE course_id='k-frei' AND weekday=3")["id"]
    conn.execute("UPDATE course_events SET attend=0 WHERE id=?", (thu,))          # der Nutzer hat sie auf „nicht besuchen“ gesetzt
    _calendar(conn)
    r = timetable.auto_import(conn)
    s = _series(conn)
    assert r["removed"] == 1, "die unveränderte Serie des Kurses ohne Kalendertermine"
    assert "Testmathe ohne Kalender|1|10:00|Hörsaal K3|1" not in s
    assert "Testmathe ohne Kalender|3|10:00|Hörsaal K3|0" in s, "eigene Änderung bleibt"
    assert "Fragestunden Testmathe|0|14:00|Raum F1|1" in s, "jetzt eindeutig"
    assert "Übung Testprogrammierung Kalender|4|09:40|Hörsaal K2|1" in s
    assert "Tutorium Testphysik|3|08:00|Raum T1|1" in s and not any("Raum T2" in x for x in s)


def test_hand_confirmed_preview_is_never_removed(app, conn):
    """Wählt der Nutzer in der Vorschau eine Serie, die nicht im Kalender steht (z. B. den fehlenden Kurs), bleibt sie."""
    from app import db, timetable
    _seed(conn)
    _calendar(conn)
    timetable.auto_import(conn)
    chosen = [e for e in timetable.studip_entries(conn) if e.get("course_id") == "k-frei"][:1]
    conn.commit()
    status, _, body = asgi_call(app, "POST", "/api/timetable/import/confirm", body=json.dumps({"entries": chosen, "source": "studip"}))
    assert status == 200 and json.loads(body)["new"] == 1
    assert db.row(conn, "SELECT source FROM course_events WHERE course_id='k-frei'")["source"] == "studip-manual"
    assert timetable.auto_import(conn)["removed"] == 0
    assert db.row(conn, "SELECT COUNT(*) n FROM course_events WHERE course_id='k-frei'")["n"] == 1


def test_decisions_survive_when_the_dates_are_past(conn):
    """Am Semesterende gibt es keine künftigen Termine mehr: die gespeicherte Entscheidung gilt weiter."""
    from app import db, timetable
    _seed(conn)
    _calendar(conn)
    timetable.auto_import(conn)
    conn.execute("UPDATE studip_calendar_dates SET fetched_at='2027-03-01T08:00:00'")       # alles liegt jetzt zurück
    timetable.auto_import(conn)
    assert _series(conn) == WITH_CALENDAR
    assert db.row(conn, "SELECT relevant FROM studip_series_relevance WHERE series='k-prog|0|12:00|13:00'")["relevant"] == 0


def test_diff_same_course_same_day_needs_overlapping_time(conn):
    """Zwei Serien desselben Kurses am selben Tag (Vorlesung und Fragestunde, zwei Übungen) sind keine Doppel."""
    from app import timetable
    conn.execute("""INSERT INTO course_events(course_id, title, kind, weekday, start_time, end_time, rrule, attend, source, created_at)
                    VALUES ('k-diff', 'Mathe I', 'vorlesung', 0, '10:00', '11:30', 'weekly', 1, 'studip', '2026-10-27')""")
    e = lambda st, en, course="k-diff", title="Mathe I": {"title": title, "weekday": 0, "start_time": st, "end_time": en, "course_id": course}
    d = timetable.diff_against_existing(conn, [e("10:00", "11:30"), e("14:00", "15:30")])
    assert len(d["same"]) == 1 and [x["start_time"] for x in d["new"]] == ["14:00"], "Fragestunde am Nachmittag ist neu"
    d = timetable.diff_against_existing(conn, [e("10:15", "11:45")])
    assert len(d["changed"]) == 1 and d["changed"][0]["old_start"] == "10:00", "überlappend = geändert"
    d = timetable.diff_against_existing(conn, [e("10:00", "11:30", course="k-anders")])
    assert len(d["new"]) == 1, "anderer Kurs, gleiche Zeit und gleicher Titel: eigene Serie"
    d = timetable.diff_against_existing(conn, [e("10:00", "11:30", course=None, title="Mathe I (ICS)")])
    assert len(d["new"]) == 1 and not d["same"]
    d = timetable.diff_against_existing(conn, [e("10:00", "11:30", course=None)])
    assert len(d["same"]) == 1, "ohne Kurs (Kalenderdatei) zählt der Titel"
    d = timetable.diff_against_existing(conn, [e("10:00", "11:30"), e("10:00", "11:30")])
    assert len(d["same"]) == 1 and len(d["new"]) == 1, "eine vorhandene Serie passt nur zu einem Eintrag"


def test_progress_shows_in_bg_while_running(app):
    from app import progress, server
    progress.clear()
    server._bg_state.update(running=True, task="Sync", message="")
    try:
        progress.report("Datei 3 von 7 herunterladen – Programmieren I")
        assert server._bg()["message"] == "Sync: Datei 3 von 7 herunterladen – Programmieren I"
        status, _, body = asgi_call(app, "GET", "/api/bg")
        assert status == 200 and "Datei 3 von 7" in json.loads(body)["message"]
    finally:
        server._bg_state.update(running=False, task=None, message="")
        progress.clear()
    progress.report("alt")
    assert server._bg()["message"] == "", "ohne laufenden Abgleich kein Zwischenstand"
    progress.clear()


def test_pending_downloads_counts_what_store_course_files_loads(app, tmp_path, monkeypatch):
    """Die Zahl „von y“ ist genau die Zahl der Downloads danach."""
    from app import db, studip_sync
    monkeypatch.setattr(studip_sync, "_files_dir", lambda: tmp_path)
    c = {"id": "k-dl", "title": "Download-Test", "number": None, "semester": ""}
    files = [{"id": f"k-dl-{i}", "name": f"blatt{i}.pdf", "size": 10, "mime": "application/pdf", "author": "", "chdate": 1790000000 + i,
              "download_url": f"https://studip.test/{i}"} for i in range(3)]
    loaded = []

    def fake(url, target, size):
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"%PDF-1.4 test")
        loaded.append(url)
    with db.cursor() as conn:
        try:
            studip_sync.upsert_course(conn, c, FETCHED)
            assert studip_sync.pending_downloads(conn, files) == 3
            studip_sync.store_course_files(conn, c, files, {}, fake, FETCHED, [], pause=0)
            assert len(loaded) == 3 and studip_sync.pending_downloads(conn, files) == 0
            newer = [{**files[0], "chdate": files[0]["chdate"] + 100}] + files[1:]
            assert studip_sync.pending_downloads(conn, newer) == 1
        finally:
            conn.execute("DELETE FROM files WHERE course_id='k-dl'")
            conn.execute("DELETE FROM courses WHERE id='k-dl'")
