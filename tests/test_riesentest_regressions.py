"""Befunde des Riesentests vom 03.11.2026 (docs/RIESENTEST-2026-11-03.md) gegen die synthetischen Hochschulen:
Kurstitel aus Stud.IP der LUH, die vorher kein gemeinsames Fach ergaben, und ein Pruefungstermin, der als Raumhinweis
galt. Gleiche Faelle im Swift-Kern ueber fixtures/hildesheim/expected.json (HildesheimSyncTests.testRulesMatchPython)."""
from datetime import date, timedelta

import pytest

from app import announcements
from app.studip_sync import classify


@pytest.mark.parametrize("title, subject, kind", [
    ("Übung zur Vorlesung Signale und Systeme", "Signale und Systeme", "uebung"),
    ("Fragestunde zur Vorlesung Mathematik für Ingenieure I", "Mathematik für Ingenieure I", "uebung"),
    ("Tutorien Programmieren I", "Programmieren I", "tutorium"),
    ("Übung Programmieren I - Gruppe 7", "Programmieren I", "uebung"),
    ("Vorlesung und Übung Numerische Mathematik", "Numerische Mathematik", "vorlesung"),
    ("Vorlesung + Übung Technische Mechanik II", "Technische Mechanik II", "vorlesung"),
    ("Grundlagen der Elektrotechnik I (Gruppe B)", "Grundlagen der Elektrotechnik I", "vorlesung"),
    # unveraendert: "Vorlesungsbegleitend" ist keine Art-Angabe, alte Muster bleiben
    ("Übung Vorlesungsbegleitende Statistik", "Vorlesungsbegleitende Statistik", "uebung"),
    ("Übung zu Grundlagen der Elektrotechnik I", "Grundlagen der Elektrotechnik I", "uebung"),
    ("Gruppenübung zu Grundlagen der Elektrotechnik I (Tranche B)", "Grundlagen der Elektrotechnik I", "gruppenuebung"),
    ("Tutorium Physik", "Physik", "tutorium"),
])
def test_classify_unifies_luh_title_patterns(title, subject, kind):
    assert classify(title) == (subject, kind)


def test_family_of_one_subject_becomes_one_module_name():
    titles = ["Mathematik für Ingenieure I", "Übung zur Vorlesung Mathematik für Ingenieure I", "Hörsaalübung Mathematik für Ingenieure I",
              "Gruppenübungen zu Mathematik für Ingenieure I, Tranche 2", "Tutorien Mathematik für Ingenieure I",
              "Fragestunde zur Vorlesung Mathematik für Ingenieure I", "Übung Mathematik für Ingenieure I - Gruppe 3"]
    assert {classify(t)[0] for t in titles} == {"Mathematik für Ingenieure I"}


@pytest.mark.parametrize("text, kind", [
    ("Die Klausur findet am 12.02.2027 um 9 Uhr im Hörsaal F 303 statt.", "pruefung"),
    ("Abgabe im Raum 101 bis zum 12.11.2026.", "frist"),
    ("Raumänderung: ab 4.11. in HC.N.0.08 (Hörsaal 4).", "raum"),
])
def test_exam_and_deadline_beat_room_hint(text, kind):
    dates = announcements.extract_dates(text, date(2026, 11, 3))
    assert len(dates) == 1 and dates[0]["kind"] == kind


def test_single_dates_are_not_parallel_groups(app):
    """Ohne Kalender: eine Vorlesung mit zwei Serien und einem Nachholtermin kam nicht in den Stundenplan ("3 parallele
    Gruppen"); ein Blockseminar aus vier Einzelterminen ebenso wenig. Einzeltermine zaehlen nicht als Gruppen."""
    from app import db, studip_sync, timetable
    with db.cursor() as conn:
        conn.execute("DELETE FROM course_events")
        for cid, title in (("k-rt-vl", "Riesentest Vorlesung"), ("k-rt-block", "Riesentest Blockseminar")):
            studip_sync.upsert_course(conn, {"id": cid, "title": title, "number": None, "semester": "WiSe 2026/27"}, "2026-11-03T10:00:00")
            conn.execute("UPDATE courses SET active=1 WHERE id=?", (cid,))
        events = []
        for week in range(14):                                       # Montag und Donnerstag ab 12.10.2026, dazu ein Ersatztermin
            for day, hm in ((12 + 7 * week, "08:15"), (15 + 7 * week, "14:00")):
                d = date(2026, 10, 1) + timedelta(days=day - 1)
                events.append({"id": f"rt-vl-{day}-{hm}", "course_id": "k-rt-vl", "title": "Sitzung", "start": f"{d.isoformat()}T{hm}:00",
                               "end": f"{d.isoformat()}T{hm[:2]}:{'45' if hm == '08:15' else '30'}:00".replace("08:45", "09:45").replace("14:30", "15:30"), "room": "F 102"})
        events.append({"id": "rt-vl-ersatz", "course_id": "k-rt-vl", "title": "Ersatztermin", "start": "2026-11-18T16:00:00", "end": "2026-11-18T17:30:00", "room": "F 102"})
        for n, (day, hm) in enumerate((("2026-11-06", "09:00"), ("2026-11-14", "10:00"), ("2026-12-03", "13:00"), ("2026-12-19", "09:00"))):   # unregelmaessig
            events.append({"id": f"rt-block-{n}", "course_id": "k-rt-block", "title": "Block", "start": f"{day}T{hm}:00", "end": f"{day}T16:00:00", "room": "A 1"})
        studip_sync.store_events(conn, events)
        entries = [e for e in timetable.studip_entries(conn) if e.get("course_id", "").startswith("k-rt-")]
        assert entries and all(e["selected"] for e in entries), [(e["title"], e["rrule"], e.get("group_slots")) for e in entries]
        assert sorted(e["rrule"] for e in entries if e["course_id"] == "k-rt-vl") == ["once", "weekly", "weekly"]
        assert all(e["group_slots"] == 2 for e in entries if e["course_id"] == "k-rt-vl")
        assert all(e["rrule"] == "once" and e["group_slots"] == 0 for e in entries if e["course_id"] == "k-rt-block")
        conn.execute("DELETE FROM studip_events WHERE course_id LIKE 'k-rt-%'")
        conn.execute("DELETE FROM courses WHERE id LIKE 'k-rt-%'")


def test_studip_api_get_retries_rate_limit_and_server_errors(monkeypatch):
    """429 und 5xx werden bis zu zweimal wiederholt (wie stream_download und UniRetry im Kern); 403 nicht."""
    from app import studip_sync

    class Resp:
        def __init__(self, status):
            self.status, self.ok = status, 200 <= status < 300

        def json(self):
            return {"data": []}

    class Request:
        def __init__(self, statuses):
            self.statuses, self.calls = list(statuses), 0

        def get(self, url, headers=None, **k):
            self.calls += 1
            return Resp(self.statuses.pop(0) if self.statuses else 200)

    class Page:
        def __init__(self, statuses):
            self.request = Request(statuses)

    monkeypatch.setattr(studip_sync.time, "sleep", lambda s: None)
    page = Page([429, 503, 200])
    assert studip_sync.api_get(page, "https://studip.synth.invalid/x").status == 200 and page.request.calls == 3
    page = Page([503, 503, 503, 200])
    assert studip_sync.api_get(page, "https://studip.synth.invalid/x").status == 503 and page.request.calls == 3, "hoechstens drei Versuche"
    page = Page([403])
    assert studip_sync.api_get(page, "https://studip.synth.invalid/x").status == 403 and page.request.calls == 1, "403 wird nicht wiederholt"
    page = Page([429, 200])
    assert studip_sync.api_list(page, "https://studip.synth.invalid/jsonapi.php/v1/folders/f/file-refs?page[limit]=500") == []
